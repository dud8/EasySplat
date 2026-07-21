import CryptoKit
import Darwin
import ImageIO
import SQLite3
import UniformTypeIdentifiers
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

    func testValidatePlyRejectsViewerIncompatibleGaussianPropertyTypes() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let requiredFloatProperties = [
            "x", "y", "z",
            "f_dc_0", "f_dc_1", "f_dc_2",
            "scale_0", "scale_1", "scale_2", "opacity",
            "rot_0", "rot_1", "rot_2", "rot_3",
        ]
        for property in requiredFloatProperties {
            let output = root.appendingPathComponent("wrong-type-\(property).ply")
            try TestFileBuilder.writeMinimalPly(at: output)
            let canonical = try String(contentsOf: output, encoding: .utf8)
            let mutated = canonical.replacingOccurrences(
                of: "property float \(property)\n",
                with: "property double \(property)\n"
            )
            XCTAssertNotEqual(mutated, canonical)
            try mutated.write(to: output, atomically: true, encoding: .utf8)

            guard case .corrupt = ProjectArtifactValidator.validatePlyFile(at: output) else {
                XCTFail("Expected the viewer-incompatible \(property) type to be rejected")
                continue
            }
        }
    }

    func testValidatePlyUsesProductionViewerReadabilityContract() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalURL = root.appendingPathComponent("canonical.ply")
        try TestFileBuilder.writeMinimalPly(at: canonicalURL)
        let canonical = try String(contentsOf: canonicalURL, encoding: .utf8)

        let fixtures: [(String, String)] = [
            (
                "incomplete-normal.ply",
                canonical.replacingOccurrences(
                    of: "property float x\n",
                    with: "property float x\nproperty float nx\n"
                )
            ),
            (
                "incomplete-higher-order-color.ply",
                canonical.replacingOccurrences(
                    of: "property float scale_0\n",
                    with: "property float f_rest_0\nproperty float scale_0\n"
                )
            ),
            (
                "extra-ascii-value.ply",
                canonical.replacingOccurrences(
                    of: "0 0 0 1 1 1 -4 -4 -4 1 1 0 0 0",
                    with: "0 0 0 1 1 1 -4 -4 -4 1 1 0 0 0 99"
                )
            ),
            (
                "crlf-header.ply",
                canonical.replacingOccurrences(of: "\n", with: "\r\n")
            ),
        ]

        for (name, contents) in fixtures {
            let output = root.appendingPathComponent(name)
            try contents.write(to: output, atomically: true, encoding: .utf8)
            guard case .corrupt = ProjectArtifactValidator.validatePlyFile(at: output) else {
                XCTFail("Expected \(name) to be rejected by the production viewer contract")
                continue
            }
        }
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

    func testValidatedPlyEvidenceAtBindsExactVisibleBytes() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output.ply")
        try TestFileBuilder.writeMinimalPly(at: output, vertexCount: 12)
        let bytes = try Data(contentsOf: output)

        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(at: output)

        XCTAssertEqual(evidence.byteCount, UInt64(bytes.count))
        XCTAssertEqual(evidence.vertexCount, 12)
        XCTAssertEqual(evidence.format, "ascii")
        XCTAssertTrue(evidence.sceneBounds.isValid)
        XCTAssertEqual(
            evidence.sha256,
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        )
    }

    func testValidatedPlyBoundsAreInvariantToInputRowOrder() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let forward = root.appendingPathComponent("forward.ply")
        let reversed = root.appendingPathComponent("reversed.ply")
        try writeBoundsSamplingRegressionPly(at: forward, reversed: false)
        try writeBoundsSamplingRegressionPly(at: reversed, reversed: true)

        let forwardBounds = try ProjectArtifactValidator.validatedPlyEvidence(
            at: forward
        ).sceneBounds
        let reversedBounds = try ProjectArtifactValidator.validatedPlyEvidence(
            at: reversed
        ).sceneBounds

        XCTAssertEqual(forwardBounds.center.x, 500, accuracy: 1e-9)
        XCTAssertEqual(reversedBounds.center.x, 500, accuracy: 1e-9)
        XCTAssertTrue(SplatSceneBoundsCalculator.matches(forwardBounds, reversedBounds))
    }

    func testValidatedPlyEvidenceRejectsSwapAndRestoreBeforeBoundsMeasurement() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output.ply")
        let replacement = root.appendingPathComponent("replacement.ply")
        let held = root.appendingPathComponent("held.ply")
        try TestFileBuilder.writeMinimalPly(at: output, vertexCount: 3)
        try TestFileBuilder.writeMinimalPly(at: replacement, vertexCount: 4)

        XCTAssertThrowsError(try ProjectArtifactValidator.test_validatedPlyEvidence(
            at: output,
            beforeBoundsMeasurement: {
                try FileManager.default.moveItem(at: output, to: held)
                try FileManager.default.moveItem(at: replacement, to: output)
                try FileManager.default.moveItem(at: output, to: replacement)
                try FileManager.default.moveItem(at: held, to: output)
            }
        ))
    }

    func testValidatedPlyEvidenceAtRejectsLinkedFiles() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("output.ply")
        let symlink = root.appendingPathComponent("linked.ply")
        let hardlink = root.appendingPathComponent("hardlinked.ply")
        try TestFileBuilder.writeMinimalPly(at: output)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: output)

        XCTAssertThrowsError(try ProjectArtifactValidator.validatedPlyEvidence(at: symlink))
        XCTAssertEqual(Darwin.link(output.path, hardlink.path), 0)
        XCTAssertThrowsError(try ProjectArtifactValidator.validatedPlyEvidence(at: output))
        XCTAssertThrowsError(try ProjectArtifactValidator.validatedPlyEvidence(at: hardlink))
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

    func testPublishValidatedPlyRejectsNonFiniteBinaryVerticesInEitherEndian() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        for fixture in [
            (name: "little-nan", format: "binary_little_endian", bits: UInt32(0x7fc0_0000)),
            (name: "big-infinity", format: "binary_big_endian", bits: UInt32(0x7f80_0000)),
        ] {
            let source = root.appendingPathComponent("\(fixture.name).ply")
            let destination = root.appendingPathComponent("\(fixture.name)-published.ply")
            try writeBinarySplat(
                at: source,
                format: fixture.format,
                firstFloatBits: fixture.bits
            )

            guard case .corrupt(let reason) = ProjectArtifactValidator.validatePlyFile(at: source) else {
                return XCTFail("Expected \(fixture.name) to be rejected")
            }
            XCTAssertTrue(reason.contains("invalid vertex value for x"), reason)
            XCTAssertThrowsError(
                try ProjectArtifactValidator.publishValidatedPly(from: source, to: destination)
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testValidatePlyBoundsUnterminatedAsciiVertexRows() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = root.appendingPathComponent("oversized-row.ply")
        var data = Data("""
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
        """.utf8)
        data.append(0x0a)
        data.append(Data(repeating: 0x31, count: 1_100_000))
        try data.write(to: invalid)

        guard case .corrupt(let reason) = ProjectArtifactValidator.validatePlyFile(at: invalid) else {
            return XCTFail("Expected an oversized unterminated ASCII row to be rejected")
        }
        XCTAssertTrue(reason.contains("oversized vertex row"), reason)
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

    func testPublishValidatedPlyAtomicallyPublishesExactEvidence() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        let destinationDirectory = root.appendingPathComponent("published", isDirectory: true)
        let destination = destinationDirectory.appendingPathComponent("splat.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 17)
        let sourceData = try Data(contentsOf: source)

        let evidence = try ProjectArtifactValidator.publishValidatedPly(
            from: source,
            to: destination
        )

        XCTAssertEqual(try Data(contentsOf: destination), sourceData)
        XCTAssertEqual(evidence.byteCount, UInt64(sourceData.count))
        XCTAssertEqual(
            evidence.sha256,
            SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined()
        )
        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: destination), .valid)
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((attributes[.referenceCount] as? NSNumber)?.intValue, 1)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: destinationDirectory.path)
                .contains(where: { $0.hasSuffix(".tmp") })
        )
    }

    func testPublishValidatedPlyReplacesExistingRegularDestination() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        let destination = root.appendingPathComponent("destination.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        try TestFileBuilder.writeMinimalPly(at: destination, vertexCount: 1)
        let sourceData = try Data(contentsOf: source)

        let evidence = try ProjectArtifactValidator.publishValidatedPly(
            from: source,
            to: destination
        )

        XCTAssertEqual(try Data(contentsOf: destination), sourceData)
        XCTAssertEqual(evidence.vertexCount, 3)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: { $0.contains(".previous.") || $0.hasSuffix(".tmp") })
        )
    }

    func testPublishValidatedPlyRestoresAConcurrentDestinationReplacementAndReportsConflict() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        let destination = root.appendingPathComponent("destination.ply")
        let foreign = root.appendingPathComponent("foreign.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        try TestFileBuilder.writeMinimalPly(at: destination, vertexCount: 1)
        try TestFileBuilder.writeMinimalPly(at: foreign, vertexCount: 7)
        let foreignBytes = try Data(contentsOf: foreign)

        var calls = PlyPublicationSystemCalls.system()
        let liveRename = calls.renameExclusively
        var injectedReplacement = false
        calls.renameExclusively = { directory, sourceName, destinationName in
            if !injectedReplacement, sourceName == destination.lastPathComponent {
                injectedReplacement = true
                guard Darwin.rename(foreign.path, destination.path) == 0 else {
                    errno = EIO
                    return -1
                }
            }
            return liveRename(directory, sourceName, destinationName)
        }

        XCTAssertThrowsError(
            try ProjectArtifactValidator.publishValidatedPly(
                from: source,
                to: destination,
                expected: nil,
                systemCalls: calls
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectArtifactError,
                .publicationConflict("destination.ply")
            )
        }

        XCTAssertTrue(injectedReplacement)
        XCTAssertEqual(try Data(contentsOf: destination), foreignBytes)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: { $0.contains(".previous.") || $0.hasSuffix(".tmp") })
        )
    }

    func testPublishValidatedPlyReportsConflictWhenAnExistingDestinationDisappearsBeforeRename() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        let destination = root.appendingPathComponent("destination.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        try TestFileBuilder.writeMinimalPly(at: destination, vertexCount: 1)

        var calls = PlyPublicationSystemCalls.system()
        let liveRename = calls.renameExclusively
        var removedDestination = false
        calls.renameExclusively = { directory, sourceName, destinationName in
            if !removedDestination, sourceName == destination.lastPathComponent {
                removedDestination = true
                guard Darwin.unlink(destination.path) == 0 else {
                    errno = EIO
                    return -1
                }
            }
            return liveRename(directory, sourceName, destinationName)
        }

        XCTAssertThrowsError(
            try ProjectArtifactValidator.publishValidatedPly(
                from: source,
                to: destination,
                expected: nil,
                systemCalls: calls
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectArtifactError,
                .publicationConflict(destination.lastPathComponent)
            )
        }
        XCTAssertTrue(removedDestination)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: { $0.contains(".previous.") || $0.hasSuffix(".tmp") })
        )
    }

    func testPublishValidatedPlyRestoresPriorWhenFirstBackupStatusFailsAfterRename() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        let destination = root.appendingPathComponent("destination.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        try TestFileBuilder.writeMinimalPly(at: destination, vertexCount: 1)
        let priorBytes = try Data(contentsOf: destination)

        var calls = PlyPublicationSystemCalls.system()
        let liveStatus = calls.status
        var injectedFailure = false
        calls.status = { directory, name, metadata in
            if !injectedFailure, name.contains(".previous.") {
                injectedFailure = true
                errno = EIO
                return -1
            }
            return liveStatus(directory, name, metadata)
        }

        XCTAssertThrowsError(
            try ProjectArtifactValidator.publishValidatedPly(
                from: source,
                to: destination,
                expected: nil,
                systemCalls: calls
            )
        )

        XCTAssertTrue(injectedFailure)
        XCTAssertEqual(try Data(contentsOf: destination), priorBytes)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: {
                    $0.contains(".previous.")
                        || $0.contains(".rollback.")
                        || $0.hasSuffix(".tmp")
                })
        )
    }

    func testPublishValidatedPlyReportsConflictAndPreservesAConcurrentDestinationCreation() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        let destination = root.appendingPathComponent("destination.ply")
        let foreign = root.appendingPathComponent("foreign.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        try TestFileBuilder.writeMinimalPly(at: foreign, vertexCount: 7)
        let foreignBytes = try Data(contentsOf: foreign)

        var calls = PlyPublicationSystemCalls.system()
        let liveRename = calls.renameExclusively
        var injectedDestination = false
        calls.renameExclusively = { directory, sourceName, destinationName in
            if !injectedDestination, destinationName == destination.lastPathComponent {
                injectedDestination = true
                guard Darwin.rename(foreign.path, destination.path) == 0 else {
                    errno = EIO
                    return -1
                }
            }
            return liveRename(directory, sourceName, destinationName)
        }

        XCTAssertThrowsError(
            try ProjectArtifactValidator.publishValidatedPly(
                from: source,
                to: destination,
                expected: nil,
                systemCalls: calls
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectArtifactError,
                .publicationConflict(destination.lastPathComponent)
            )
        }
        XCTAssertTrue(injectedDestination)
        XCTAssertEqual(try Data(contentsOf: destination), foreignBytes)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: { $0.contains(".previous.") || $0.hasSuffix(".tmp") })
        )
    }

    func testPublishValidatedPlyPreservesBothFilesWhenACompetitorAppearsAfterBackup() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        let destination = root.appendingPathComponent("destination.ply")
        let foreign = root.appendingPathComponent("foreign.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        try TestFileBuilder.writeMinimalPly(at: destination, vertexCount: 1)
        try TestFileBuilder.writeMinimalPly(at: foreign, vertexCount: 7)
        let priorBytes = try Data(contentsOf: destination)
        let foreignBytes = try Data(contentsOf: foreign)

        var calls = PlyPublicationSystemCalls.system()
        let liveRename = calls.renameExclusively
        var movedPriorAside = false
        var injectedCompetitor = false
        calls.renameExclusively = { directory, sourceName, destinationName in
            if sourceName == destination.lastPathComponent {
                let result = liveRename(directory, sourceName, destinationName)
                movedPriorAside = result == 0
                return result
            }
            if movedPriorAside,
               !injectedCompetitor,
               destinationName == destination.lastPathComponent {
                injectedCompetitor = true
                guard Darwin.rename(foreign.path, destination.path) == 0 else {
                    errno = EIO
                    return -1
                }
            }
            return liveRename(directory, sourceName, destinationName)
        }

        var recoveredLeaf: String?
        XCTAssertThrowsError(
            try ProjectArtifactValidator.publishValidatedPly(
                from: source,
                to: destination,
                expected: nil,
                systemCalls: calls
            )
        ) { error in
            guard let artifactError = error as? ProjectArtifactError,
                  case .publicationConflictPreservingPrevious(
                destination.lastPathComponent,
                let leaf
            ) = artifactError else {
                return XCTFail("Unexpected error: \(error)")
            }
            recoveredLeaf = leaf
        }

        XCTAssertTrue(injectedCompetitor)
        XCTAssertEqual(try Data(contentsOf: destination), foreignBytes)
        let recoveredURL = root.appendingPathComponent(try XCTUnwrap(recoveredLeaf))
        XCTAssertEqual(try Data(contentsOf: recoveredURL), priorBytes)
        XCTAssertFalse(recoveredURL.lastPathComponent.hasPrefix("."))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: { $0.contains(".previous.") || $0.hasSuffix(".tmp") })
        )
    }

    func testPublishValidatedPlyPreservesEveryCompetitorAcrossNestedRollbackRace() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        let destination = root.appendingPathComponent("destination.ply")
        let firstForeign = root.appendingPathComponent("first-foreign.ply")
        let secondForeign = root.appendingPathComponent("second-foreign.ply")
        let displacedPublication = root.appendingPathComponent("displaced-publication.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        try TestFileBuilder.writeMinimalPly(at: destination, vertexCount: 1)
        try TestFileBuilder.writeMinimalPly(at: firstForeign, vertexCount: 7)
        try TestFileBuilder.writeMinimalPly(at: secondForeign, vertexCount: 11)
        let priorBytes = try Data(contentsOf: destination)
        let firstForeignBytes = try Data(contentsOf: firstForeign)
        let secondForeignBytes = try Data(contentsOf: secondForeign)

        var calls = PlyPublicationSystemCalls.system()
        let liveSynchronize = calls.synchronize
        var synchronizations = 0
        calls.synchronize = { descriptor in
            synchronizations += 1
            if synchronizations == 2 {
                errno = EIO
                return -1
            }
            return liveSynchronize(descriptor)
        }
        let liveRename = calls.renameExclusively
        var injectedFirstCompetitor = false
        var injectedSecondCompetitor = false
        calls.renameExclusively = { directory, sourceName, destinationName in
            if !injectedFirstCompetitor,
               sourceName == destination.lastPathComponent,
               destinationName.contains(".rollback.") {
                injectedFirstCompetitor = true
                guard Darwin.rename(destination.path, displacedPublication.path) == 0,
                      Darwin.rename(firstForeign.path, destination.path) == 0 else {
                    errno = EIO
                    return -1
                }
            } else if !injectedSecondCompetitor,
               sourceName.contains(".rollback."),
               destinationName == destination.lastPathComponent {
                injectedSecondCompetitor = true
                guard Darwin.rename(secondForeign.path, destination.path) == 0 else {
                    errno = EIO
                    return -1
                }
            }
            return liveRename(directory, sourceName, destinationName)
        }

        var recoveredLeaves: [String] = []
        XCTAssertThrowsError(
            try ProjectArtifactValidator.publishValidatedPly(
                from: source,
                to: destination,
                expected: nil,
                systemCalls: calls
            )
        ) { error in
            guard let artifactError = error as? ProjectArtifactError,
                  case .publicationConflictPreservingFiles(
                    destination.lastPathComponent,
                    let leaves
                  ) = artifactError else {
                return XCTFail("Unexpected error: \(error)")
            }
            recoveredLeaves = leaves
        }

        XCTAssertTrue(injectedFirstCompetitor)
        XCTAssertTrue(injectedSecondCompetitor)
        XCTAssertEqual(try Data(contentsOf: destination), secondForeignBytes)
        XCTAssertEqual(recoveredLeaves.count, 2)
        let recoveredBytes = try recoveredLeaves.map {
            try Data(contentsOf: root.appendingPathComponent($0))
        }
        XCTAssertEqual(Set(recoveredBytes), Set([priorBytes, firstForeignBytes]))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: {
                    $0.contains(".previous.")
                        || $0.contains(".rollback.")
                        || $0.hasSuffix(".tmp")
                })
        )
    }

    func testPublishValidatedPlyCancelsBetweenPartialCopyWritesWithoutReplacingDestination() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        let destination = root.appendingPathComponent("destination.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 32)
        try TestFileBuilder.writeMinimalPly(at: destination, vertexCount: 2)
        let sourceBytes = try Data(contentsOf: source)
        let destinationBytes = try Data(contentsOf: destination)

        let publication = Task.detached { () throws -> ValidatedPlyArtifactEvidence in
            var calls = PlyPublicationSystemCalls.system()
            let liveWrite = calls.write
            var writes = 0
            calls.write = { descriptor, bytes, count in
                writes += 1
                let result = liveWrite(descriptor, bytes, min(count, 32))
                if writes == 2 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return result
            }
            return try ProjectArtifactValidator.publishValidatedPly(
                from: source,
                to: destination,
                expected: nil,
                systemCalls: calls
            )
        }

        do {
            _ = try await publication.value
            XCTFail("Expected cooperative cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }

        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: destination), destinationBytes)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: { $0.contains(".previous.") || $0.hasSuffix(".tmp") })
        )
    }

    func testPublishValidatedPlyCancelsBetweenTemporaryHashChunksWithoutReplacingDestination() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        let destination = root.appendingPathComponent("destination.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 32)
        try TestFileBuilder.writeMinimalPly(at: destination, vertexCount: 2)
        let sourceBytes = try Data(contentsOf: source)
        let destinationBytes = try Data(contentsOf: destination)

        var calls = PlyPublicationSystemCalls.system()
        let liveReadAt = calls.readAt
        var sourceDescriptor: Int32?
        var temporaryHashReads = 0
        let cancellation = PlyPublicationCancellationProbe()
        calls.readAt = { descriptor, bytes, count, offset in
            if sourceDescriptor == nil {
                sourceDescriptor = descriptor
            }
            let result = liveReadAt(descriptor, bytes, min(count, 64), offset)
            if descriptor != sourceDescriptor, result > 0 {
                temporaryHashReads += 1
                if temporaryHashReads == 1 {
                    cancellation.cancel()
                }
            }
            return result
        }

        XCTAssertThrowsError(
            try ProjectArtifactValidator.publishValidatedPly(
                from: source,
                to: destination,
                expected: nil,
                systemCalls: calls,
                shouldCancel: { cancellation.isCancelled }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }

        XCTAssertEqual(temporaryHashReads, 1)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: destination), destinationBytes)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: { $0.contains(".previous.") || $0.hasSuffix(".tmp") })
        )
    }

    func testPublishValidatedPlyCancelsDuringPostPublicationHashAndRestoresDestination() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        let destination = root.appendingPathComponent("destination.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 32)
        try TestFileBuilder.writeMinimalPly(at: destination, vertexCount: 2)
        let sourceBytes = try Data(contentsOf: source)
        let destinationBytes = try Data(contentsOf: destination)

        var calls = PlyPublicationSystemCalls.system()
        let liveReadAt = calls.readAt
        var sourceDescriptor: Int32?
        var temporaryHashPasses = 0
        let cancellation = PlyPublicationCancellationProbe()
        calls.readAt = { descriptor, bytes, count, offset in
            if sourceDescriptor == nil {
                sourceDescriptor = descriptor
            }
            if descriptor != sourceDescriptor, offset == 0 {
                temporaryHashPasses += 1
                if temporaryHashPasses == 2 {
                    cancellation.cancel()
                }
            }
            return liveReadAt(descriptor, bytes, min(count, 64), offset)
        }

        XCTAssertThrowsError(
            try ProjectArtifactValidator.publishValidatedPly(
                from: source,
                to: destination,
                expected: nil,
                systemCalls: calls,
                shouldCancel: { cancellation.isCancelled }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }

        XCTAssertEqual(temporaryHashPasses, 2)
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: destination), destinationBytes)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: {
                    $0.contains(".previous.")
                        || $0.contains(".rollback.")
                        || $0.hasSuffix(".tmp")
                })
        )
    }

    func testPublishValidatedPlyRejectsExistingSymlinkDestinationWithoutReplacingIt() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        let target = root.appendingPathComponent("target.ply")
        let destination = root.appendingPathComponent("destination.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 3)
        try TestFileBuilder.writeMinimalPly(at: target, vertexCount: 1)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)

        XCTAssertThrowsError(
            try ProjectArtifactValidator.publishValidatedPly(from: source, to: destination)
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: target), .valid)
    }

    func testPublishValidatedPlyPreservesForeignReplacementWhenDirectorySyncFails() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        let destination = root.appendingPathComponent("destination.ply")
        let displacedPublication = root.appendingPathComponent("displaced-publication.ply")
        let foreign = root.appendingPathComponent("foreign.ply")
        let sentinel = Data("foreign replacement".utf8)
        try TestFileBuilder.writeMinimalPly(at: source)
        try sentinel.write(to: foreign)
        var calls = PlyPublicationSystemCalls.system()
        let liveSynchronize = calls.synchronize
        var synchronizations = 0
        calls.synchronize = { descriptor in
            synchronizations += 1
            if synchronizations == 2 {
                guard Darwin.rename(destination.path, displacedPublication.path) == 0,
                      Darwin.rename(foreign.path, destination.path) == 0 else {
                    errno = EIO
                    return -1
                }
                errno = EIO
                return -1
            }
            return liveSynchronize(descriptor)
        }

        XCTAssertThrowsError(
            try ProjectArtifactValidator.publishValidatedPly(
                from: source,
                to: destination,
                expected: nil,
                systemCalls: calls
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectArtifactError,
                .publicationConflict(destination.lastPathComponent)
            )
        }

        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: displacedPublication.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: { $0.contains(".rollback.") })
        )
    }

    func testPublishValidatedPlyReturnsCommittedOutputWhenBackupCleanupSyncFails() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        let destination = root.appendingPathComponent("destination.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 9)
        try TestFileBuilder.writeMinimalPly(at: destination, vertexCount: 2)
        let sourceBytes = try Data(contentsOf: source)

        var calls = PlyPublicationSystemCalls.system()
        let liveSynchronize = calls.synchronize
        var synchronizations = 0
        calls.synchronize = { descriptor in
            synchronizations += 1
            if synchronizations == 3 {
                errno = EIO
                return -1
            }
            return liveSynchronize(descriptor)
        }

        let evidence = try ProjectArtifactValidator.publishValidatedPly(
            from: source,
            to: destination,
            expected: nil,
            systemCalls: calls
        )

        XCTAssertEqual(synchronizations, 3)
        XCTAssertEqual(try Data(contentsOf: destination), sourceBytes)
        XCTAssertEqual(evidence.byteCount, UInt64(sourceBytes.count))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: {
                    $0.contains(".previous.")
                        || $0.contains(".rollback.")
                        || $0.hasSuffix(".tmp")
                })
        )
    }

    func testPublishValidatedPlyHonorsCancellationBeforeBackupDeletion() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        let destination = root.appendingPathComponent("destination.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 9)
        try TestFileBuilder.writeMinimalPly(at: destination, vertexCount: 2)
        let priorBytes = try Data(contentsOf: destination)

        var calls = PlyPublicationSystemCalls.system()
        let liveStatus = calls.status
        let cancellation = PlyPublicationCancellationProbe()
        var destinationStatusCalls = 0
        calls.status = { directory, name, metadata in
            let result = liveStatus(directory, name, metadata)
            if result == 0, name == destination.lastPathComponent {
                destinationStatusCalls += 1
                if destinationStatusCalls == 7 {
                    cancellation.cancel()
                }
            }
            return result
        }

        XCTAssertThrowsError(
            try ProjectArtifactValidator.publishValidatedPly(
                from: source,
                to: destination,
                expected: nil,
                systemCalls: calls,
                shouldCancel: { cancellation.isCancelled }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }

        XCTAssertEqual(destinationStatusCalls, 8)
        XCTAssertEqual(try Data(contentsOf: destination), priorBytes)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: {
                    $0.contains(".previous.")
                        || $0.contains(".rollback.")
                        || $0.hasSuffix(".tmp")
                })
        )
    }

    func testPublishValidatedPlyDoesNotDeleteReplacementBetweenBackupStatusAndCleanup() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        let destination = root.appendingPathComponent("destination.ply")
        let displacedPrior = root.appendingPathComponent("displaced-prior.ply")
        let foreign = root.appendingPathComponent("foreign.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 9)
        try TestFileBuilder.writeMinimalPly(at: destination, vertexCount: 2)
        try TestFileBuilder.writeMinimalPly(at: foreign, vertexCount: 13)
        let sourceBytes = try Data(contentsOf: source)
        let priorBytes = try Data(contentsOf: destination)
        let foreignBytes = try Data(contentsOf: foreign)

        var calls = PlyPublicationSystemCalls.system()
        let liveStatus = calls.status
        var backupStatusCalls = 0
        var injectedReplacement = false
        calls.status = { directory, name, metadata in
            let result = liveStatus(directory, name, metadata)
            if result == 0, name.contains(".previous.") {
                backupStatusCalls += 1
                if backupStatusCalls == 2 {
                    injectedReplacement = true
                    let backupURL = root.appendingPathComponent(name)
                    guard Darwin.rename(backupURL.path, displacedPrior.path) == 0,
                          Darwin.rename(foreign.path, backupURL.path) == 0 else {
                        errno = EIO
                        return -1
                    }
                }
            }
            return result
        }

        var recoveredLeaves: [String] = []
        XCTAssertThrowsError(
            try ProjectArtifactValidator.publishValidatedPly(
                from: source,
                to: destination,
                expected: nil,
                systemCalls: calls
            )
        ) { error in
            guard let artifactError = error as? ProjectArtifactError,
                  case .publicationConflictPreservingFiles(
                    destination.lastPathComponent,
                    let leaves
                  ) = artifactError else {
                return XCTFail("Unexpected error: \(error)")
            }
            recoveredLeaves = leaves
        }

        XCTAssertTrue(injectedReplacement)
        XCTAssertEqual(try Data(contentsOf: destination), sourceBytes)
        XCTAssertEqual(try Data(contentsOf: displacedPrior), priorBytes)
        XCTAssertEqual(recoveredLeaves.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent(recoveredLeaves[0])),
            foreignBytes
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: {
                    $0.contains(".previous.")
                        || $0.contains(".rollback.")
                        || $0.contains(".cleanup.")
                        || $0.hasSuffix(".tmp")
                })
        )
    }

    func testPublishValidatedPlyRecoversQuarantineWhenRollbackStatusFails() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        let destination = root.appendingPathComponent("destination.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 9)
        let sourceBytes = try Data(contentsOf: source)

        var calls = PlyPublicationSystemCalls.system()
        let liveSynchronize = calls.synchronize
        var synchronizations = 0
        calls.synchronize = { descriptor in
            synchronizations += 1
            if synchronizations == 2 {
                errno = EIO
                return -1
            }
            return liveSynchronize(descriptor)
        }
        let liveStatus = calls.status
        var failedRollbackStatus = false
        calls.status = { directory, name, metadata in
            if !failedRollbackStatus, name.contains(".rollback.") {
                failedRollbackStatus = true
                errno = EIO
                return -1
            }
            return liveStatus(directory, name, metadata)
        }

        XCTAssertThrowsError(
            try ProjectArtifactValidator.publishValidatedPly(
                from: source,
                to: destination,
                expected: nil,
                systemCalls: calls
            )
        )

        XCTAssertTrue(failedRollbackStatus)
        XCTAssertEqual(try Data(contentsOf: destination), sourceBytes)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: {
                    $0.contains(".rollback.") || $0.hasSuffix(".tmp")
                })
        )
    }

    func testPublishValidatedPlyPreservesSameInodeSameSizeMutationAfterDirectorySync() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        let destination = root.appendingPathComponent("destination.ply")
        try TestFileBuilder.writeMinimalPly(at: source)
        let originalBytes = try Data(contentsOf: source)
        var calls = PlyPublicationSystemCalls.system()
        let liveSynchronize = calls.synchronize
        var synchronizations = 0
        var mutatedBytes: Data?
        calls.synchronize = { descriptor in
            synchronizations += 1
            let result = liveSynchronize(descriptor)
            if result == 0, synchronizations == 2 {
                do {
                    try self.mutateFirstVertexCoordinate(at: destination)
                    mutatedBytes = try Data(contentsOf: destination)
                } catch {
                    errno = EIO
                    return -1
                }
            }
            return result
        }

        XCTAssertThrowsError(
            try ProjectArtifactValidator.publishValidatedPly(
                from: source,
                to: destination,
                expected: nil,
                systemCalls: calls
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectArtifactError,
                .publicationConflict(destination.lastPathComponent)
            )
        }

        XCTAssertEqual(try Data(contentsOf: destination), try XCTUnwrap(mutatedBytes))
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: { $0.contains(".rollback.") || $0.hasSuffix(".tmp") })
        )
    }

    func testPublishValidatedPlyPreservesForeignReplacementAfterLateMutation() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        let destination = root.appendingPathComponent("destination.ply")
        let displacedPublication = root.appendingPathComponent("displaced-publication.ply")
        let foreign = root.appendingPathComponent("foreign.ply")
        let sentinel = Data("foreign replacement".utf8)
        try TestFileBuilder.writeMinimalPly(at: source)
        try sentinel.write(to: foreign)
        var calls = PlyPublicationSystemCalls.system()
        let liveStatus = calls.status
        var statusCalls = 0
        calls.status = { directory, name, metadata in
            statusCalls += 1
            let result = liveStatus(directory, name, metadata)
            if result == 0, statusCalls == 3 {
                do {
                    try self.mutateFirstVertexCoordinate(at: destination)
                    guard Darwin.rename(destination.path, displacedPublication.path) == 0,
                          Darwin.rename(foreign.path, destination.path) == 0 else {
                        errno = EIO
                        return -1
                    }
                } catch {
                    errno = EIO
                    return -1
                }
            }
            return result
        }

        XCTAssertThrowsError(
            try ProjectArtifactValidator.publishValidatedPly(
                from: source,
                to: destination,
                expected: nil,
                systemCalls: calls
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectArtifactError,
                .publicationConflict(destination.lastPathComponent)
            )
        }

        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
        XCTAssertTrue(FileManager.default.fileExists(atPath: displacedPublication.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: { $0.contains(".rollback.") })
        )
    }

    func testPublishValidatedPlyRejectsLinkedSources() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source)
        let symlink = root.appendingPathComponent("symlink.ply")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: source)
        XCTAssertThrowsError(
            try ProjectArtifactValidator.publishValidatedPly(
                from: symlink,
                to: root.appendingPathComponent("symlink-output.ply")
            )
        )

        let hardlink = root.appendingPathComponent("hardlink.ply")
        XCTAssertEqual(Darwin.link(source.path, hardlink.path), 0)
        XCTAssertThrowsError(
            try ProjectArtifactValidator.publishValidatedPly(
                from: source,
                to: root.appendingPathComponent("hardlink-output.ply")
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("hardlink-output.ply").path
            )
        )
    }

    func testPublishValidatedPlyRejectsInvalidSourceWithoutLeavingStagingFiles() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("invalid.ply")
        let destination = root.appendingPathComponent("output.ply")
        try Data("not a ply".utf8).write(to: source)

        XCTAssertThrowsError(
            try ProjectArtifactValidator.publishValidatedPly(from: source, to: destination)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains(where: { $0.hasPrefix(".output.ply.") })
        )
    }

    func testPublishValidatedPlyRequiresExactExpectedTrainingIdentity() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 9)
        let data = try Data(contentsOf: source)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        for (index, expected) in [
            ExpectedPlyArtifactIdentity(
                byteCount: UInt64(data.count + 1),
                vertexCount: 9,
                sha256: digest
            ),
            ExpectedPlyArtifactIdentity(
                byteCount: UInt64(data.count),
                vertexCount: 8,
                sha256: digest
            ),
            ExpectedPlyArtifactIdentity(
                byteCount: UInt64(data.count),
                vertexCount: 9,
                sha256: String(repeating: "0", count: 64)
            ),
        ].enumerated() {
            let destination = root.appendingPathComponent("rejected-\(index).ply")
            XCTAssertThrowsError(
                try ProjectArtifactValidator.publishValidatedPly(
                    from: source,
                    to: destination,
                    expected: expected
                )
            )
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }

        let accepted = root.appendingPathComponent("accepted.ply")
        let evidence = try ProjectArtifactValidator.publishValidatedPly(
            from: source,
            to: accepted,
            expected: ExpectedPlyArtifactIdentity(
                byteCount: UInt64(data.count),
                vertexCount: 9,
                sha256: digest
            )
        )
        XCTAssertEqual(evidence.vertexCount, 9)
        XCTAssertEqual(evidence.format, "ascii")
    }

    func testValidateFinishedProjectBindsCurrentMetadataArtifactsPlanAndOutput() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let evidence = try ProjectArtifactValidator.validateFinishedProject(
            at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
            context: fixture.validationContext
        )

        XCTAssertEqual(evidence.metadata.id, fixture.metadata.id)
        XCTAssertEqual(evidence.metadata.state.stage, .done)
        XCTAssertEqual(evidence.requestedRunOptions, fixture.metadata.requestedRunOptions)
        XCTAssertEqual(evidence.resolvedRunPlan, fixture.plan)
        XCTAssertEqual(
            evidence.toolchainRequest,
            try fixture.plan.toolchainCapabilityRequest()
        )
        XCTAssertEqual(evidence.geometryArtifact, fixture.geometry)
        XCTAssertEqual(evidence.trainingArtifact, fixture.training)
        XCTAssertEqual(evidence.outputURL.standardizedFileURL, fixture.output.standardizedFileURL)
        XCTAssertEqual(evidence.outputEvidence, fixture.outputEvidence)
        guard case .photos(let folder) = evidence.input else {
            return XCTFail("Expected the finished project to preserve its photo input.")
        }
        XCTAssertEqual(folder, "Originals/Photos")
    }

    func testValidatePublishedGeometryDoesNotRequireTrainingOrOutput() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.paths.trainingManifestURL)
        try FileManager.default.removeItem(at: fixture.output)

        let geometry = try ProjectArtifactValidator.validatePublishedGeometry(
            at: fixture.paths.root,
            expectedGeometry: fixture.geometry
        )

        XCTAssertEqual(geometry, fixture.geometry)
    }

    func testValidatePublishedGeometryRejectsDifferentCameraInitializationEvidence() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var featureEvidence = try ColmapFeatureEvidenceStore.load(
            from: fixture.paths.colmapFeatureEvidenceURL,
            projectPaths: fixture.paths
        )
        featureEvidence.cameraInitializationReceipt.cameraModel = "PINHOLE"
        try ColmapFeatureEvidenceStore.save(
            featureEvidence,
            to: fixture.paths.colmapFeatureEvidenceURL,
            projectPaths: fixture.paths
        )

        XCTAssertThrowsError(
            try ProjectArtifactValidator.validatePublishedGeometry(
                at: fixture.paths.root,
                expectedGeometry: fixture.geometry
            )
        )
    }

    func testValidatePublishedGeometryRejectsClassicalArtifactUnderDa3Plan() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var metadata = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        var relabeledPlan = try XCTUnwrap(metadata.resolvedRunPlan)
        relabeledPlan.geometryBackend = .da3
        relabeledPlan.modelIdentifier = "DA3-BASE"
        relabeledPlan.requiredToolchainCapabilities = [
            ToolchainCapability.colmap.rawValue,
            ToolchainCapability.core.rawValue,
            ToolchainCapability.da3Base.rawValue,
            ToolchainCapability.da3Runtime.rawValue,
            ToolchainCapability.msplat.rawValue,
        ].sorted()
        try relabeledPlan.validate()
        metadata.resolvedRunPlan = relabeledPlan
        try ProjectMetadataStore.save(metadata, to: fixture.paths.metadataURL)

        XCTAssertThrowsError(
            try ProjectArtifactValidator.validatePublishedGeometry(
                at: fixture.paths.root,
                expectedGeometry: fixture.geometry
            )
        )
    }

    func testPairGraphReproductionUsesDa3BackendAndModelBinding() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var plan = fixture.plan
        plan.geometryBackend = .da3
        plan.modelIdentifier = "DA3-BASE"
        plan.requiredToolchainCapabilities = [
            ToolchainCapability.colmap.rawValue,
            ToolchainCapability.core.rawValue,
            ToolchainCapability.da3Base.rawValue,
            ToolchainCapability.da3Runtime.rawValue,
            ToolchainCapability.msplat.rawValue,
        ].sorted()
        try plan.validate()

        let imageNames = fixture.geometry.orderedImageNames
        let manifest = Da3CoverageManifest(
            mode: "seed_refine",
            requestedDevice: "mps",
            selectedDevice: "mps",
            modelSubdirectory: plan.modelIdentifier,
            processResolution: 504,
            cameraType: "perspective",
            sharedCamera: true,
            maxPoints: 100,
            totalImages: imageNames.count,
            windowSize: imageNames.count,
            windowOverlap: 0,
            windows: [
                Da3CoverageManifest.Window(
                    start: 0,
                    end: imageNames.count,
                    images: imageNames,
                    indices: Array(imageNames.indices)
                )
            ],
            rawPointSampleCount: 50,
            fusedSparsePointCount: 25,
            finalObservationCount: nil,
            meanTrackLength: nil,
            registeredImageCount: imageNames.count,
            nativeColmapExport: false,
            exportStrategy: "aligned_pose_depth_seed",
            inputOrdering: plan.inputOrdering.rawValue,
            anchorImageNames: imageNames,
            alignmentEdgeCount: 0,
            maxAlignmentRMSE: 0,
            alignmentComplete: true
        )
        try JSONEncoder().encode(manifest).write(
            to: fixture.paths.da3CoverageManifestURL,
            options: .atomic
        )
        let pairPlan = try ColmapPairEstimator.validatedDa3RefinementPairPlan(
            manifest: manifest,
            imageNames: imageNames,
            resolvedPlan: plan
        )
        let inspection = try ColmapPairGraphInspector(
            databaseURL: fixture.paths.colmapDatabaseURL
        ).inspect(
            schedule: ColmapPairSchedule(
                imageNames: imageNames,
                pairs: pairPlan.pairs
            ),
            completion: .succeeded
        )
        let attempt = PairGraphAttemptEvidence(
            artifact: PairMatchingAttemptArtifact(
                attemptNumber: 1,
                matcher: .faiss,
                recoveryLevel: .normal,
                outcome: .completed,
                scheduledPairCount: pairPlan.pairs.count,
                attemptedPairCount: inspection.attemptedPairCount,
                rawMatchedPairCount: inspection.rawMatchedPairCount,
                spatiallyVerifiedPairCount: inspection.spatiallyVerifiedPairCount,
                durationSeconds: 0.01
            ),
            scheduledPairs: pairPlan.pairs
        )
        let planBinding = PairGraphPlanBinding(plan)
        let evidence = PairGraphEvidence(
            selectedFramesDigest: fixture.geometry.selectedFramesDigest,
            imageNames: imageNames,
            pairingPolicy: plan.pairingPolicy,
            planBinding: planBinding,
            attempts: [attempt],
            acceptedAttemptNumber: 1,
            acceptedInspection: inspection,
            retrievalWasScheduled: false,
            usedLocalVocabularyRetrieval: false,
            matchingDurationSeconds: 0.01,
            fallbackReasons: []
        )
        try PairGraphEvidenceStore.saveDa3Refinement(
            evidence,
            expectedPlanBinding: planBinding,
            expectedPairPlan: pairPlan,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
        var geometry = fixture.geometry
        geometry.pairGraph = try PairGraphEvidenceStore.da3PairGraphArtifact(
            evidence,
            expectedPlanBinding: planBinding,
            expectedPairPlan: pairPlan
        )
        let selectedFrameManifest = try JSONDecoder().decode(
            [PipelineRunner.SelectedFrameMapping].self,
            from: Data(contentsOf: fixture.paths.framesSelectedManifestURL)
        )

        XCTAssertEqual(
            try ProjectArtifactValidator.test_reproducePairGraph(
                plan: plan,
                geometry: geometry,
                selectedFrameManifest: selectedFrameManifest,
                paths: fixture.paths
            ),
            geometry.pairGraph
        )

        var wrongModelPlan = plan
        wrongModelPlan.modelIdentifier = "DA3-SMALL"
        XCTAssertThrowsError(
            try ProjectArtifactValidator.test_reproducePairGraph(
                plan: wrongModelPlan,
                geometry: geometry,
                selectedFrameManifest: selectedFrameManifest,
                paths: fixture.paths
            )
        )
    }

    func testMeasurementPlanBindingAcceptsProactivelySelectedDa3SmallOnly() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let revision = "89abcdef0123456789abcdef0123456789abcdef"
        var geometry = fixture.geometry
        geometry.modelVersion = "DA3-SMALL@\(revision)"
        geometry.provenance.runtime = GeometryComponentProvenance(
            identifier: "da3_mps",
            version: "main",
            revision: "a0b8a92e3d1532361c2f7feb63babc5c18d00ef2",
            payloadSHA256: String(repeating: "b", count: 64)
        )
        geometry.provenance.model = GeometryComponentProvenance(
            identifier: "DA3-SMALL",
            version: "apache-2.0-release",
            revision: revision,
            payloadSHA256: String(repeating: "c", count: 64)
        )
        var smallPlan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .fast,
                cameraGrouping: .sameCameraAndLens,
                lensProjection: .perspective,
                inputOrdering: .unordered
            ),
            input: .photos(folder: "/tmp/photos"),
            hardware: HardwareProfile(memoryGB: 16, cpuCount: 16, gpuWorkingSetGB: 12),
            developmentOverrides: DevelopmentOverrides(candidateRoute: .da3)
        )
        XCTAssertEqual(smallPlan.modelIdentifier, "DA3-SMALL")
        smallPlan.geometryWorkerBudget = geometry.workerExecution.resolvedBudget
        smallPlan.cameraGrouping = geometry.cameraGrouping
        smallPlan.pairingPolicy = fixture.plan.pairingPolicy

        XCTAssertNoThrow(
            try ProjectArtifactValidator.test_requireGeometryPlanBinding(
                geometry,
                plan: smallPlan
            )
        )

        var basePlan = smallPlan
        basePlan.modelIdentifier = "DA3-BASE"
        basePlan.requiredToolchainCapabilities = [
            ToolchainCapability.colmap.rawValue,
            ToolchainCapability.core.rawValue,
            ToolchainCapability.da3Base.rawValue,
            ToolchainCapability.da3Runtime.rawValue,
            ToolchainCapability.msplat.rawValue,
        ].sorted()
        XCTAssertThrowsError(
            try ProjectArtifactValidator.test_requireGeometryPlanBinding(
                geometry,
                plan: basePlan
            )
        )
    }

    func testValidatePublishedGeometryRejectsCameraDatabasePriorMutation() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try setPrivateMode(fixture.paths.colmapDatabaseURL)
        var database: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open(fixture.paths.colmapDatabaseURL.path, &database),
            SQLITE_OK
        )
        let opened = try XCTUnwrap(database)
        XCTAssertEqual(
            sqlite3_exec(
                opened,
                "UPDATE cameras SET prior_focal_length = 1;",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        sqlite3_close(opened)
        try setProjectArtifactMode(fixture.paths.colmapDatabaseURL)

        XCTAssertThrowsError(
            try ProjectArtifactValidator.validatePublishedGeometry(
                at: fixture.paths.root,
                expectedGeometry: fixture.geometry
            )
        )
    }

    func testValidatePublishedGeometryRejectsResolvedPlanRecipeTampering() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try Data(contentsOf: fixture.paths.metadataURL)
        var document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: original) as? [String: Any]
        )
        var plan = try XCTUnwrap(document["resolvedRunPlan"] as? [String: Any])
        XCTAssertEqual(plan["cameraInitializationRecipe"] as? String, "colmapAutomatic")
        plan["cameraInitializationRecipe"] =
            "sharedOpenCVFisheyeEquidistantDiagonal150V1"
        document["resolvedRunPlan"] = plan
        let tampered = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys]
        )
        try tampered.write(to: fixture.paths.metadataURL, options: .atomic)

        XCTAssertThrowsError(
            try ProjectArtifactValidator.validatePublishedGeometry(
                at: fixture.paths.root,
                expectedGeometry: fixture.geometry
            )
        )
    }

    func testValidateFinishedProjectAuthenticatesRawSourceSeparatelyFromDevelopedPNG() throws {
        let fixture = try makeFinishedProjectFixture(includesRawSource: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let rawSourceURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.input,
                includingPropertiesForKeys: nil
            ).first(where: { $0.pathExtension.lowercased() == "dng" })
        )
        let rawImageSource = try XCTUnwrap(CGImageSourceCreateWithURL(
            rawSourceURL as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ))
        XCTAssertEqual(CGImageSourceGetCount(rawImageSource), 1)
        XCTAssertEqual(CGImageSourceGetType(rawImageSource) as String?, "com.adobe.raw-image")

        let evidence = try ProjectArtifactValidator.validateFinishedProject(
            at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
            context: fixture.validationContext
        )

        let rawReceipt = try XCTUnwrap(
            evidence.metadata.photoInputReceipts?.first(where: {
                if case .rawDevelopment = $0.importMode { return true }
                return false
            })
        )
        XCTAssertNotEqual(rawReceipt.source.sha256, rawReceipt.sha256)
        XCTAssertNotEqual(rawReceipt.source.byteCount, rawReceipt.byteCount)
        XCTAssertTrue(try XCTUnwrap(UTType(rawReceipt.source.typeIdentifier)).conforms(to: .rawImage))
        XCTAssertEqual(rawReceipt.typeIdentifier, UTType.png.identifier)
    }

    func testValidateFinishedRawProjectRejectsSourceAndControlledOutputForgery() throws {
        for mutation in RawFinishedProjectMutation.allCases {
            let fixture = try makeFinishedProjectFixture(includesRawSource: true)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            var metadata = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
            let receipts = try XCTUnwrap(metadata.photoInputReceipts)
            let rawIndex = try XCTUnwrap(receipts.firstIndex(where: {
                if case .rawDevelopment = $0.importMode { return true }
                return false
            }))
            let receipt = receipts[rawIndex]

            switch mutation {
            case .sourceReplacement:
                let source = try XCTUnwrap(
                    FileManager.default.enumerator(
                        at: fixture.input,
                        includingPropertiesForKeys: nil
                    )?.allObjects.compactMap { $0 as? URL }.first(where: {
                        $0.pathExtension.lowercased() == "dng"
                    })
                )
                var bytes = try Data(contentsOf: source)
                bytes[bytes.startIndex] ^= 0xff
                try bytes.write(to: source, options: .atomic)

            case .sourceTypeSpoof:
                var replaced = receipts
                replaced[rawIndex] = rawReceipt(
                    from: receipt,
                    source: PhotoSourceProvenance(
                        byteCount: receipt.source.byteCount,
                        sha256: receipt.source.sha256,
                        typeIdentifier: UTType.png.identifier
                    ),
                    importMode: receipt.importMode
                )
                metadata.photoInputReceipts = replaced
                try writeUncheckedProjectMetadata(metadata, to: fixture.paths.metadataURL)
                try setPrivateMode(fixture.paths.metadataURL)

            case .sourceContentTypeSpoof:
                let source = try XCTUnwrap(
                    FileManager.default.enumerator(
                        at: fixture.input,
                        includingPropertiesForKeys: nil
                    )?.allObjects.compactMap { $0 as? URL }.first(where: {
                        $0.pathExtension.lowercased() == "dng"
                    })
                )
                XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
                    url: source,
                    size: 16,
                    value: 32,
                    utType: .jpeg
                ))
                let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
                var replaced = receipts
                replaced[rawIndex] = rawReceipt(
                    from: receipt,
                    source: PhotoSourceProvenance(
                        byteCount: try XCTUnwrap(attributes[.size] as? NSNumber).int64Value,
                        sha256: try GeometryArtifactStore.sha256(of: source),
                        typeIdentifier: "com.adobe.raw-image"
                    ),
                    importMode: receipt.importMode
                )
                metadata.photoInputReceipts = replaced
                try writeUncheckedProjectMetadata(metadata, to: fixture.paths.metadataURL)
                try setPrivateMode(fixture.paths.metadataURL)

            case .missingDevelopmentProvenance:
                var replaced = receipts
                replaced[rawIndex] = rawReceipt(
                    from: receipt,
                    source: receipt.source,
                    importMode: .unchanged
                )
                metadata.photoInputReceipts = replaced
                try writeUncheckedProjectMetadata(metadata, to: fixture.paths.metadataURL)
                try setPrivateMode(fixture.paths.metadataURL)

            case .controlledReplacement:
                let controlled = try fixture.paths.resolveProjectRelativePath(
                    receipt.projectRelativePath
                )
                XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
                    url: controlled,
                    size: receipt.pixelWidth,
                    value: 7,
                    utType: .png
                ))
                try setPrivateMode(controlled)

            case .sourceControlledDigestSwap:
                var replaced = receipts
                replaced[rawIndex] = rawReceipt(
                    from: receipt,
                    source: PhotoSourceProvenance(
                        byteCount: receipt.byteCount,
                        sha256: receipt.sha256,
                        typeIdentifier: receipt.source.typeIdentifier
                    ),
                    importMode: receipt.importMode
                )
                metadata.photoInputReceipts = replaced
                try writeUncheckedProjectMetadata(metadata, to: fixture.paths.metadataURL)
                try setPrivateMode(fixture.paths.metadataURL)

            case .extraControlledFile:
                let extra = fixture.paths.importedPhotosURL.appendingPathComponent("unrecorded.png")
                XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
                    url: extra,
                    size: 16,
                    value: 127,
                    utType: .png
                ))
                try setPrivateMode(extra)
            }

            XCTAssertThrowsError(
                try ProjectArtifactValidator.validateFinishedProject(
                    at: fixture.paths.root,
                    expectedInput: .photoFolder(fixture.input),
                    context: fixture.validationContext
                ),
                "Mutation unexpectedly passed: \(mutation)"
            )
        }
    }

    func testValidateFinishedProjectRejectsPhotoOrderOutsideVisualDiversityProjection() throws {
        let fixture = try makeFinishedProjectFixture(canonicalPhotoOrder: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(
            try ProjectArtifactValidator.validateFinishedProject(
                at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
                context: fixture.validationContext
            )
        )
    }

    func testValidateFinishedProjectRejectsSelectedPhotoRetainedRankForgery() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let data = try Data(contentsOf: fixture.paths.framesSelectedManifestURL)
        var records = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        records[0]["photoRetainedRank"] = records[1]["photoRetainedRank"]
        try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]).write(
            to: fixture.paths.framesSelectedManifestURL,
            options: .atomic
        )
        try setProjectArtifactMode(fixture.paths.framesSelectedManifestURL)

        XCTAssertThrowsError(
            try ProjectArtifactValidator.validateFinishedProject(
                at: fixture.paths.root,
                expectedInput: .photoFolder(fixture.input),
                context: fixture.validationContext
            )
        )
    }

    func testValidateFinishedProjectRejectsMissingSelectedPhotoRetainedRank() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let data = try Data(contentsOf: fixture.paths.framesSelectedManifestURL)
        var records = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        records[0].removeValue(forKey: "photoRetainedRank")
        try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]).write(
            to: fixture.paths.framesSelectedManifestURL,
            options: .atomic
        )
        try setProjectArtifactMode(fixture.paths.framesSelectedManifestURL)

        XCTAssertThrowsError(
            try ProjectArtifactValidator.validateFinishedProject(
                at: fixture.paths.root,
                expectedInput: .photoFolder(fixture.input),
                context: fixture.validationContext
            )
        )
    }

    func testValidateFinishedProjectRejectsSwappedSelectedPhotoRetainedRanks() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let data = try Data(contentsOf: fixture.paths.framesSelectedManifestURL)
        var records = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        let first = records[0]["photoRetainedRank"]
        records[0]["photoRetainedRank"] = records[1]["photoRetainedRank"]
        records[1]["photoRetainedRank"] = first
        try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]).write(
            to: fixture.paths.framesSelectedManifestURL,
            options: .atomic
        )
        try setProjectArtifactMode(fixture.paths.framesSelectedManifestURL)

        XCTAssertThrowsError(
            try ProjectArtifactValidator.validateFinishedProject(
                at: fixture.paths.root,
                expectedInput: .photoFolder(fixture.input),
                context: fixture.validationContext
            )
        )
    }

    func testFinishedVisualPhotoProjectionRequiresExactRankedPrefix() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let metadata = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        let projection = try XCTUnwrap(PhotoSelectionProjection.loadVerified(
            metadata: metadata,
            paths: fixture.paths
        ))
        let expected = try projection.project(targetCount: 2)
        let exactPrefix = expected.map {
            ($0.projectRelativePath, $0.sha256, $0.retainedRank)
        }
        XCTAssertNoThrow(
            try ProjectArtifactValidator.test_requireExactPhotoProjection(
                exactPrefix,
                projection: projection,
                targetCount: 2
            )
        )

        let skippedRank = projection.rankOrderedReceipts[2]
        XCTAssertThrowsError(
            try ProjectArtifactValidator.test_requireExactPhotoProjection(
                [
                    exactPrefix[0],
                    (
                        skippedRank.projectRelativePath,
                        skippedRank.sha256,
                        skippedRank.retainedRank
                    ),
                ],
                projection: projection,
                targetCount: 2
            )
        )

        XCTAssertThrowsError(
            try ProjectArtifactValidator.test_requireExactPhotoProjection(
                [
                    (
                        exactPrefix[0].0,
                        String(repeating: "0", count: 64),
                        exactPrefix[0].2
                    ),
                    exactPrefix[1],
                ],
                projection: projection,
                targetCount: 2
            )
        )
    }

    func testFinishedPhotoProjectionHonorsContinuousSpacingAndUseAll() throws {
        let continuousFixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: continuousFixture.root) }
        let continuous = try authenticatedPhotoProjection(
            in: continuousFixture,
            inputOrdering: .continuous,
            photoSelection: .automatic
        )
        let expectedContinuous = try continuous.project(targetCount: 2).map {
            ($0.projectRelativePath, $0.sha256, $0.retainedRank)
        }
        XCTAssertNoThrow(
            try ProjectArtifactValidator.test_requireExactPhotoProjection(
                expectedContinuous,
                projection: continuous,
                targetCount: 2
            )
        )
        let wrongContinuousPrefix = Array(continuous.canonicalReceipts.prefix(2)).map {
            ($0.projectRelativePath, $0.sha256, $0.retainedRank)
        }
        XCTAssertThrowsError(
            try ProjectArtifactValidator.test_requireExactPhotoProjection(
                wrongContinuousPrefix,
                projection: continuous,
                targetCount: 2
            )
        )

        let useAllFixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: useAllFixture.root) }
        let useAll = try authenticatedPhotoProjection(
            in: useAllFixture,
            inputOrdering: .unordered,
            photoSelection: .useAllValidPhotos
        )
        let incompleteUseAll = Array(useAll.canonicalReceipts.prefix(2)).map {
            ($0.projectRelativePath, $0.sha256, $0.retainedRank)
        }
        XCTAssertThrowsError(
            try ProjectArtifactValidator.test_requireExactPhotoProjection(
                incompleteUseAll,
                projection: useAll,
                targetCount: 2
            )
        )
        XCTAssertNoThrow(
            try ProjectArtifactValidator.test_requireExactPhotoProjection(
                useAll.canonicalReceipts.map {
                    ($0.projectRelativePath, $0.sha256, $0.retainedRank)
                },
                projection: useAll,
                targetCount: useAll.canonicalReceipts.count
            )
        )
    }

    func testFinishedSnapshotRejectsPhotoSelectionArtifactMutation() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(
            try ProjectArtifactValidator.test_validateFinishedProjectSnapshotBinding(
                at: fixture.paths.root,
                expectedInput: .photoFolder(fixture.input),
                context: fixture.validationContext,
                mutation: {
                    var data = try Data(contentsOf: fixture.paths.photoSelectionArtifactURL)
                    data[data.startIndex] ^= 0x01
                    try data.write(
                        to: fixture.paths.photoSelectionArtifactURL,
                        options: .atomic
                    )
                    try self.setProjectArtifactMode(fixture.paths.photoSelectionArtifactURL)
                }
            )
        )
    }

    func testValidateFinishedProjectRejectsSceneBoundsNotDerivedFromOutput() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var metadata = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        var forged = fixture.training
        forged.sceneBounds = SplatSceneBounds(
            center: ScenePoint3D(x: 10_000, y: -20_000, z: 30_000),
            radius: 1_000_000
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(forged).write(
            to: fixture.paths.trainingManifestURL,
            options: [.atomic]
        )
        metadata.state = PipelineState(stage: .done, lastError: nil)
        try ProjectMetadataStore.save(metadata, to: fixture.paths.metadataURL)
        try setPrivateMode(fixture.paths.trainingManifestURL)
        try setPrivateMode(fixture.paths.metadataURL)

        XCTAssertThrowsError(
            try ProjectArtifactValidator.validateFinishedProject(
                at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
                context: fixture.validationContext
            )
        )
    }

    func testValidateFinishedProjectBindsGeometryAndTrainingToSignedToolchain() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let finished = try ProjectArtifactValidator.validateFinishedProject(
            at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
            context: fixture.validationContext
        )
        let colmapSHA256 = try XCTUnwrap(
            fixture.geometry.workerExecution.colmapRuntimeClosure.sha256(
                for: "bin/colmap"
            )
        )
        let matching = makeToolchainEvidence(
            toolchainVersion: fixture.geometry.provenance.toolchainVersion,
            colmapSHA256: colmapSHA256,
            trainerBuildDigest: fixture.training.trainerBuildDigest
        )

        XCTAssertNoThrow(
            try ProjectArtifactValidator.validateToolchainBinding(
                finishedProject: finished,
                installation: matching
            )
        )

        let mismatches = [
            makeToolchainEvidence(
                toolchainVersion: "2.0.1",
                colmapSHA256: colmapSHA256,
                trainerBuildDigest: fixture.training.trainerBuildDigest
            ),
            makeToolchainEvidence(
                toolchainVersion: fixture.geometry.provenance.toolchainVersion,
                colmapSHA256: String(repeating: "b", count: 64),
                trainerBuildDigest: fixture.training.trainerBuildDigest
            ),
            makeToolchainEvidence(
                toolchainVersion: fixture.geometry.provenance.toolchainVersion,
                colmapSHA256: colmapSHA256,
                trainerBuildDigest: String(repeating: "4", count: 64)
            ),
            makeToolchainEvidence(
                toolchainVersion: fixture.geometry.provenance.toolchainVersion,
                colmapSHA256: colmapSHA256,
                trainerBuildDigest: fixture.training.trainerBuildDigest,
                colmapSourceVersion: "4.0.4"
            ),
            makeToolchainEvidence(
                toolchainVersion: fixture.geometry.provenance.toolchainVersion,
                colmapSHA256: colmapSHA256,
                trainerBuildDigest: fixture.training.trainerBuildDigest,
                duplicateColmapProvenance: true
            ),
            makeToolchainEvidence(
                toolchainVersion: fixture.geometry.provenance.toolchainVersion,
                colmapSHA256: colmapSHA256,
                trainerBuildDigest: fixture.training.trainerBuildDigest,
                openMPSHA256: String(repeating: "c", count: 64)
            ),
            makeToolchainEvidence(
                toolchainVersion: fixture.geometry.provenance.toolchainVersion,
                colmapSHA256: colmapSHA256,
                trainerBuildDigest: fixture.training.trainerBuildDigest,
                omitOpenMPFromCriticalFiles: true
            ),
            makeToolchainEvidence(
                toolchainVersion: fixture.geometry.provenance.toolchainVersion,
                colmapSHA256: colmapSHA256,
                trainerBuildDigest: fixture.training.trainerBuildDigest,
                omitOpenMPFromDeclaredContents: true
            ),
        ]
        for mismatch in mismatches {
            XCTAssertThrowsError(
                try ProjectArtifactValidator.validateToolchainBinding(
                    finishedProject: finished,
                    installation: mismatch
                )
            )
        }
    }

    func testToolchainBindingRejectsClassicalArtifactRelabeledAsDa3() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let finished = try ProjectArtifactValidator.validateFinishedProject(
            at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
            context: fixture.validationContext
        )
        let colmapSHA256 = try XCTUnwrap(
            fixture.geometry.workerExecution.colmapRuntimeClosure.sha256(
                for: "bin/colmap"
            )
        )
        let installation = makeToolchainEvidence(
            toolchainVersion: fixture.geometry.provenance.toolchainVersion,
            colmapSHA256: colmapSHA256,
            trainerBuildDigest: fixture.training.trainerBuildDigest
        )
        var relabeledPlan = finished.resolvedRunPlan
        relabeledPlan.geometryBackend = .da3
        relabeledPlan.modelIdentifier = "DA3-BASE"
        let relabeled = FinishedProjectArtifactEvidence(
            metadata: finished.metadata,
            input: finished.input,
            requestedRunOptions: finished.requestedRunOptions,
            resolvedRunPlan: relabeledPlan,
            toolchainRequest: finished.toolchainRequest,
            geometryArtifact: finished.geometryArtifact,
            trainingArtifact: finished.trainingArtifact,
            outputURL: finished.outputURL,
            outputEvidence: finished.outputEvidence
        )

        XCTAssertThrowsError(
            try ProjectArtifactValidator.validateToolchainBinding(
                finishedProject: relabeled,
                installation: installation
            )
        )
    }

    func testValidateFinishedProjectRejectsEmptyMetadata() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Empty.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: project)
        try paths.ensureDirectories()
        try Data("{}".utf8).write(to: paths.metadataURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.metadataURL.path
        )
        let input = root.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try ProjectArtifactValidator.validateFinishedProject(
                at: project,
                expectedInput: .photoFolder(input)
            )
        )
    }

    func testValidateFinishedProjectRejectsUnfinishedOrActiveState() throws {
        enum Mutation {
            case stage
            case error
            case checkpoint
            case activeStart
        }
        for mutation in [Mutation.stage, .error, .checkpoint, .activeStart] {
            let fixture = try makeFinishedProjectFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            var metadata = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
            switch mutation {
            case .stage:
                metadata.state.stage = .exportSplat
            case .error:
                metadata.state.lastError = "failed"
            case .checkpoint:
                metadata.checkpoint = PipelineCheckpoint(stage: .exportSplat)
            case .activeStart:
                metadata.lastRunStartedAt = Date()
            }
            try ProjectMetadataStore.save(metadata, to: fixture.paths.metadataURL)
            try setPrivateMode(fixture.paths.metadataURL)

            XCTAssertThrowsError(
                try ProjectArtifactValidator.validateFinishedProject(
                    at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
                    context: fixture.validationContext
                ),
                "Expected mutation \(mutation) to be rejected."
            )
        }
    }

    func testValidateFinishedProjectRejectsMissingDuplicateOrExtraStageTimings() throws {
        enum Mutation: CaseIterable {
            case missingAll
            case missingStage
            case duplicateStage
            case extraDoneStage
        }
        for mutation in Mutation.allCases {
            let fixture = try makeFinishedProjectFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            var metadata = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
            let original = try XCTUnwrap(metadata.stageTimings)
            switch mutation {
            case .missingAll:
                metadata.stageTimings = nil
            case .missingStage:
                metadata.stageTimings = Array(original.dropLast())
            case .duplicateStage:
                var duplicated = original
                duplicated[duplicated.count - 1] = original[0]
                metadata.stageTimings = duplicated
            case .extraDoneStage:
                metadata.stageTimings = original + [
                    StageTimingRecord(
                        stage: .done,
                        startedAt: Date(timeIntervalSince1970: 2_000),
                        durationSeconds: 0
                    ),
                ]
            }
            try ProjectMetadataStore.save(metadata, to: fixture.paths.metadataURL)
            try setPrivateMode(fixture.paths.metadataURL)

            XCTAssertThrowsError(
                try ProjectArtifactValidator.validateFinishedProject(
                    at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
                    context: fixture.validationContext
                ),
                "Expected timing mutation \(mutation) to be rejected."
            )
        }
    }

    func testValidateFinishedProjectSyncPathRejectsVideoWithoutIndependentRederivation() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var metadata = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        let videoBytes = Data("test-video".utf8)
        let videoDigest = SHA256.hash(data: videoBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let video = try TestFileBuilder.writeControlledVideoReceipt(
            paths: fixture.paths,
            bytes: videoBytes,
            clipGroupID: "video_sha256_\(videoDigest)"
        )
        metadata.input = .video(files: [video.receipt.projectRelativePath])
        metadata.videoInputReceipts = [video.receipt]
        metadata.photoInputReceipts = nil
        metadata.photoSelectionReceipt = nil
        try FileManager.default.removeItem(at: fixture.paths.photoSelectionArtifactURL)
        try ProjectMetadataStore.save(metadata, to: fixture.paths.metadataURL)
        try setPrivateMode(fixture.paths.metadataURL)

        XCTAssertThrowsError(
            try ProjectArtifactValidator.validateFinishedProject(
                at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
                context: fixture.validationContext
            )
        ) { error in
            XCTAssertEqual(
                error as? FinishedProjectArtifactValidationError,
                .invalidProject(
                    "video projects require independent asynchronous frame rederivation"
                )
            )
        }
    }

    func testValidateFinishedProjectSnapshotBindingRejectsCoherentMetadataReplacement() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(
            try ProjectArtifactValidator.test_validateFinishedProjectSnapshotBinding(
                at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
                context: fixture.validationContext,
                mutation: {
                    let unchanged = try ProjectMetadataStore.load(
                        from: fixture.paths.metadataURL
                    )
                    try ProjectMetadataStore.save(unchanged, to: fixture.paths.metadataURL)
                    try setPrivateMode(fixture.paths.metadataURL)
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? FinishedProjectArtifactValidationError,
                .invalidProject(
                    "the finished project changed after independent video rederivation"
                )
            )
        }
    }

    func testValidateFinishedProjectSnapshotBindingAllowsProtectedMetadataChangeTimeOnly() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertNoThrow(
            try ProjectArtifactValidator.test_validateFinishedProjectSnapshotBinding(
                at: fixture.paths.root,
                expectedInput: .photoFolder(fixture.input),
                context: fixture.validationContext,
                mutation: {
                    var before = stat()
                    XCTAssertEqual(lstat(fixture.paths.metadataURL.path, &before), 0)
                    try self.setProjectArtifactMode(fixture.paths.metadataURL)
                    var after = stat()
                    XCTAssertEqual(lstat(fixture.paths.metadataURL.path, &after), 0)
                    XCTAssertNotEqual(
                        before.st_ctimespec.tv_nsec,
                        after.st_ctimespec.tv_nsec
                    )
                }
            )
        )
    }

    func testProtectedFileIdentityRejectsSameSizeRewriteWithRestoredModificationTime() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("protected.json")
        try Data("abcdef".utf8).write(to: file)
        try setPrivateMode(file)
        var original = stat()
        XCTAssertEqual(lstat(file.path, &original), 0)

        let matches = try ProjectArtifactValidator.test_protectedFileIdentityMatchesAfterMutation(
            at: file,
            mutation: {
                let descriptor = Darwin.open(file.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
                XCTAssertGreaterThanOrEqual(descriptor, 0)
                defer { Darwin.close(descriptor) }
                var replacement = UInt8(ascii: "z")
                XCTAssertEqual(
                    withUnsafePointer(to: &replacement) {
                        Darwin.pwrite(descriptor, $0, 1, 0)
                    },
                    1
                )
                XCTAssertEqual(Darwin.fsync(descriptor), 0)
                var originalByte = UInt8(ascii: "a")
                XCTAssertEqual(
                    withUnsafePointer(to: &originalByte) {
                        Darwin.pwrite(descriptor, $0, 1, 0)
                    },
                    1
                )
                XCTAssertEqual(Darwin.fsync(descriptor), 0)
                let times = [original.st_atimespec, original.st_mtimespec]
                XCTAssertEqual(
                    times.withUnsafeBufferPointer {
                        utimensat(AT_FDCWD, file.path, $0.baseAddress, 0)
                    },
                    0
                )
            }
        )
        XCTAssertFalse(matches)
        XCTAssertEqual(try Data(contentsOf: file), Data("abcdef".utf8))
    }

    func testProtectedFileIdentityAllowsAttributeOnlyMutation() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("protected.json")
        try Data("abcdef".utf8).write(to: file)
        try setPrivateMode(file)

        let matches = try ProjectArtifactValidator.test_protectedFileIdentityMatchesAfterMutation(
            at: file,
            mutation: {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: file.path
                )
            }
        )

        XCTAssertTrue(matches)
    }

    func testProtectedFileIdentityRejectsAncestorRenameAndRestore() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project,
            withIntermediateDirectories: false
        )
        let file = project.appendingPathComponent("protected.json")
        try Data("abcdef".utf8).write(to: file)
        try setPrivateMode(file)
        let displaced = root.appendingPathComponent("Displaced", isDirectory: true)

        let matches = try ProjectArtifactValidator.test_protectedFileIdentityMatchesAfterMutation(
            at: file,
            mutation: {
                try FileManager.default.moveItem(at: project, to: displaced)
                try FileManager.default.moveItem(at: displaced, to: project)
            }
        )

        XCTAssertFalse(matches)
    }

    func testProtectedDirectoryGuardRejectsAttributeMutation() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let protected = root.appendingPathComponent("Protected", isDirectory: true)
        try FileManager.default.createDirectory(
            at: protected,
            withIntermediateDirectories: false
        )

        let accepted = try ProjectArtifactValidator.test_protectedDirectoryRejectsMutation(
            at: protected,
            mutation: {
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: protected.path
                )
            }
        )

        XCTAssertFalse(accepted)
    }

    func testValidateFinishedProjectSnapshotBindingRejectsFeatureEvidenceReplacement() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(
            try ProjectArtifactValidator.test_validateFinishedProjectSnapshotBinding(
                at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
                context: fixture.validationContext,
                mutation: {
                    let unchanged = try ColmapFeatureEvidenceStore.load(
                        from: fixture.paths.colmapFeatureEvidenceURL,
                        projectPaths: fixture.paths
                    )
                    try ColmapFeatureEvidenceStore.save(
                        unchanged,
                        to: fixture.paths.colmapFeatureEvidenceURL,
                        projectPaths: fixture.paths
                    )
                    try setProjectArtifactMode(fixture.paths.colmapFeatureEvidenceURL)
                }
            )
        ) { error in
            XCTAssertEqual(
                error as? FinishedProjectArtifactValidationError,
                .invalidProject(
                    "the finished project changed after independent video rederivation"
                )
            )
        }
    }

    func testFinishedVideoCoverageRequiresExactSourceAndCanonicalGroup() throws {
        let firstSHA256 = String(repeating: "a", count: 64)
        let secondSHA256 = String(repeating: "b", count: 64)
        func mapping(
            index: Int,
            group: String = "video_000",
            relativeSource: String = "Originals/video-0000.mov",
            sourceSHA256: String? = nil,
            isVideo: Bool = true
        ) -> PipelineRunner.SelectedFrameMapping {
            PipelineRunner.SelectedFrameMapping(
                outputFileName: String(format: "frame_%06d.jpg", index),
                groupId: group,
                isVideo: isVideo,
                timestampSeconds: isVideo ? Double(index) : nil,
                sourceProjectRelativePath: relativeSource,
                sourceSHA256: sourceSHA256 ?? (relativeSource.contains("0001")
                    ? secondSHA256
                    : firstSHA256)
            )
        }
        let valid = [
            mapping(index: 0),
            mapping(index: 1),
            mapping(
                index: 2,
                group: "video_001",
                relativeSource: "Originals/video-0001.mov"
            ),
            mapping(
                index: 3,
                group: "video_001",
                relativeSource: "Originals/video-0001.mov"
            ),
            mapping(
                index: 4,
                group: "photos",
                relativeSource: "Originals/Photos/photo-0000.jpg",
                isVideo: false
            ),
        ]
        XCTAssertNoThrow(
            try ProjectArtifactValidator.test_requireExactVideoCoverage(
                valid,
                sourceFiles: ["Originals/video-0000.mov", "Originals/video-0001.mov"],
                sourceSHA256s: [firstSHA256, secondSHA256],
                pairingPolicy: .orderedContinuous
            )
        )
        for invalid in [
            Array(valid.dropFirst()),
            valid.map {
                $0.groupId == "video_001"
                    ? mapping(
                        index: Int($0.outputFileName.dropFirst("frame_".count).prefix(6)) ?? 0,
                        group: "video_002",
                        relativeSource: "Originals/video-0001.mov"
                    )
                    : $0
            },
            valid.map {
                $0.groupId == "video_001"
                    ? mapping(
                        index: Int($0.outputFileName.dropFirst("frame_".count).prefix(6)) ?? 0,
                        group: "video_001",
                        relativeSource: "Originals/video-0000.mov"
                    )
                    : $0
            },
        ] {
            XCTAssertThrowsError(
                try ProjectArtifactValidator.test_requireExactVideoCoverage(
                    invalid,
                    sourceFiles: ["Originals/video-0000.mov", "Originals/video-0001.mov"],
                    sourceSHA256s: [firstSHA256, secondSHA256],
                    pairingPolicy: .orderedContinuous
                )
            )
        }
    }

    func testFinishedSegmentedVideoCoverageIsStableAcrossDeclaredInputPermutation() throws {
        let lowSHA256 = String(repeating: "1", count: 64)
        let highSHA256 = String(repeating: "e", count: 64)
        let lowPath = "Originals/video-0001.mov"
        let highPath = "Originals/video-0000.mov"
        let lowGroup = "video_sha256_\(lowSHA256)"
        let highGroup = "video_sha256_\(highSHA256)"

        func entry(
            _ index: Int,
            group: String,
            path: String,
            sha256: String
        ) -> PipelineRunner.SelectedFrameMapping {
            PipelineRunner.SelectedFrameMapping(
                outputFileName: String(format: "frame_%06d.jpg", index),
                groupId: group,
                isVideo: true,
                timestampSeconds: Double(index),
                sourceProjectRelativePath: path,
                sourceSHA256: sha256
            )
        }

        let canonicalManifest = [
            entry(0, group: lowGroup, path: lowPath, sha256: lowSHA256),
            entry(1, group: lowGroup, path: lowPath, sha256: lowSHA256),
            entry(2, group: highGroup, path: highPath, sha256: highSHA256),
            entry(3, group: highGroup, path: highPath, sha256: highSHA256),
        ]
        XCTAssertNoThrow(try ProjectArtifactValidator.test_requireExactVideoCoverage(
            canonicalManifest,
            sourceFiles: [highPath, lowPath],
            sourceSHA256s: [highSHA256, lowSHA256],
            pairingPolicy: .segmentedMixed
        ))
        XCTAssertNoThrow(try ProjectArtifactValidator.test_requireExactVideoCoverage(
            canonicalManifest,
            sourceFiles: [lowPath, highPath],
            sourceSHA256s: [lowSHA256, highSHA256],
            pairingPolicy: .segmentedMixed
        ))

        let reversedManifest = Array(canonicalManifest[2...] + canonicalManifest[..<2])
        XCTAssertThrowsError(try ProjectArtifactValidator.test_requireExactVideoCoverage(
            reversedManifest,
            sourceFiles: [highPath, lowPath],
            sourceSHA256s: [highSHA256, lowSHA256],
            pairingPolicy: .segmentedMixed
        ))
        for forged in [
            canonicalManifest.map {
                $0.sourceSHA256 == lowSHA256
                    ? entry(
                        Int($0.timestampSeconds ?? 0),
                        group: lowGroup,
                        path: lowPath,
                        sha256: highSHA256
                    )
                    : $0
            },
            canonicalManifest.map {
                $0.sourceSHA256 == lowSHA256
                    ? entry(
                        Int($0.timestampSeconds ?? 0),
                        group: highGroup,
                        path: lowPath,
                        sha256: lowSHA256
                    )
                    : $0
            },
            canonicalManifest.map {
                $0.sourceSHA256 == lowSHA256
                    ? entry(
                        Int($0.timestampSeconds ?? 0),
                        group: lowGroup,
                        path: highPath,
                        sha256: lowSHA256
                    )
                    : $0
            },
        ] {
            XCTAssertThrowsError(try ProjectArtifactValidator.test_requireExactVideoCoverage(
                forged,
                sourceFiles: [highPath, lowPath],
                sourceSHA256s: [highSHA256, lowSHA256],
                pairingPolicy: .segmentedMixed
            ))
        }
    }

    func testFinishedVideoInputBindingUsesReceiptInsteadOfExternalMetadataPath() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(
            root: root.appendingPathComponent("Video.easysplatproj", isDirectory: true)
        )
        let bytes = Data("receipt-bound-video".utf8)
        let (_, receipt) = try TestFileBuilder.writeControlledVideoReceipt(
            paths: paths,
            bytes: bytes,
            safeDisplayName: "source.mov"
        )
        let external = root.appendingPathComponent("source.mov")
        try bytes.write(to: external)
        let input = InputSpec.video(files: [receipt.projectRelativePath])
        let requested = RequestedRunOptions(detailProfile: .fast)
        let plan = RunPlanResolver.resolve(
            requestedOptions: requested,
            input: input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: DevelopmentOverrides(benchmarkSeed: 42)
        )
        let metadata = ProjectMetadata(
            title: "Video",
            input: input,
            videoInputReceipts: [receipt],
            requestedRunOptions: requested,
            resolvedRunPlan: plan
        )
        let encodedMetadata = try JSONEncoder().encode(metadata)
        XCTAssertFalse(String(decoding: encodedMetadata, as: UTF8.self).contains(external.path))

        XCTAssertNoThrow(try ProjectArtifactValidator.test_validateControlledInputBinding(
            metadata: metadata,
            expectedInput: .videoFiles([external]),
            paths: paths
        ))
        try Data("different-video".utf8).write(to: external)
        XCTAssertThrowsError(try ProjectArtifactValidator.test_validateControlledInputBinding(
            metadata: metadata,
            expectedInput: .videoFiles([external]),
            paths: paths
        ))
    }

    func testFinishedVideoBindingRejectsExtraEmptyOriginalsDirectory() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(
            root: root.appendingPathComponent("Video.easysplatproj", isDirectory: true)
        )
        let bytes = Data("receipt-bound-video".utf8)
        let (_, receipt) = try TestFileBuilder.writeControlledVideoReceipt(
            paths: paths,
            bytes: bytes,
            safeDisplayName: "source.mov"
        )
        let external = root.appendingPathComponent("source.mov")
        try bytes.write(to: external)
        let input = InputSpec.video(files: [receipt.projectRelativePath])
        let requested = RequestedRunOptions(detailProfile: .fast)
        let plan = RunPlanResolver.resolve(
            requestedOptions: requested,
            input: input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: DevelopmentOverrides(benchmarkSeed: 42)
        )
        let metadata = ProjectMetadata(
            title: "Video",
            input: input,
            videoInputReceipts: [receipt],
            requestedRunOptions: requested,
            resolvedRunPlan: plan
        )
        try FileManager.default.createDirectory(
            at: paths.originalsURL
                .appendingPathComponent("extra", isDirectory: true)
                .appendingPathComponent("empty", isDirectory: true),
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(try ProjectArtifactValidator.test_validateControlledInputBinding(
            metadata: metadata,
            expectedInput: .videoFiles([external]),
            paths: paths
        ))
    }

    func testFinishedMultiVideoBindingCanonicalizesSegmentedClipsButPreservesExplicitOrder() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(
            root: root.appendingPathComponent("Videos.easysplatproj", isDirectory: true)
        )
        let firstBytes = Data("receipt-bound-video-one".utf8)
        let secondBytes = Data("receipt-bound-video-two".utf8)
        let first = try TestFileBuilder.writeControlledVideoReceipt(
            paths: paths,
            index: 0,
            bytes: firstBytes,
            safeDisplayName: "first.mov",
            clipGroupID: "video_sha256_\(SHA256.hash(data: firstBytes).map { String(format: "%02x", $0) }.joined())"
        )
        let second = try TestFileBuilder.writeControlledVideoReceipt(
            paths: paths,
            index: 1,
            bytes: secondBytes,
            safeDisplayName: "second.mov",
            clipGroupID: "video_sha256_\(SHA256.hash(data: secondBytes).map { String(format: "%02x", $0) }.joined())"
        )
        let externalRoot = root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(at: externalRoot, withIntermediateDirectories: true)
        let firstExternal = externalRoot.appendingPathComponent("first.mov")
        let secondExternal = externalRoot.appendingPathComponent("second.mov")
        try firstBytes.write(to: firstExternal)
        try secondBytes.write(to: secondExternal)
        let input = InputSpec.video(files: [
            first.receipt.projectRelativePath,
            second.receipt.projectRelativePath,
        ])
        let requested = RequestedRunOptions(detailProfile: .fast)
        let plan = RunPlanResolver.resolve(
            requestedOptions: requested,
            input: input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: DevelopmentOverrides(benchmarkSeed: 42)
        )
        let metadata = ProjectMetadata(
            title: "Videos",
            input: input,
            videoInputReceipts: [first.receipt, second.receipt],
            requestedRunOptions: requested,
            resolvedRunPlan: plan
        )
        let expected = FinishedProjectExpectedInput.videoFiles([
            firstExternal,
            secondExternal,
        ])

        XCTAssertNoThrow(try ProjectArtifactValidator.test_validateControlledInputBinding(
            metadata: metadata,
            expectedInput: expected,
            paths: paths
        ))
        XCTAssertNoThrow(try ProjectArtifactValidator.test_validateControlledInputBinding(
            metadata: metadata,
            expectedInput: .videoFiles([secondExternal, firstExternal]),
            paths: paths
        ))
        XCTAssertThrowsError(try ProjectArtifactValidator.test_validateControlledInputBinding(
            metadata: metadata,
            expectedInput: .videoFiles([firstExternal]),
            paths: paths
        ))
        XCTAssertThrowsError(try ProjectArtifactValidator.test_validateControlledInputBinding(
            metadata: metadata,
            expectedInput: .videoFiles([firstExternal, secondExternal, firstExternal]),
            paths: paths
        ))
        XCTAssertThrowsError(try ProjectArtifactValidator.test_validateControlledInputBinding(
            metadata: metadata,
            expectedInput: .videoFiles([firstExternal, firstExternal]),
            paths: paths
        ))

        let orderedRequested = RequestedRunOptions(
            detailProfile: .fast,
            inputOrdering: .continuous
        )
        let orderedPlan = RunPlanResolver.resolve(
            requestedOptions: orderedRequested,
            input: input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: DevelopmentOverrides(benchmarkSeed: 42)
        )
        XCTAssertTrue(orderedPlan.requiresCrossClipRetrieval)
        let orderedFirst = try TestFileBuilder.writeControlledVideoReceipt(
            paths: paths,
            index: 0,
            bytes: firstBytes,
            safeDisplayName: "first.mov",
            clipGroupID: "video_000"
        )
        let orderedSecond = try TestFileBuilder.writeControlledVideoReceipt(
            paths: paths,
            index: 1,
            bytes: secondBytes,
            safeDisplayName: "second.mov",
            clipGroupID: "video_001"
        )
        let orderedMetadata = ProjectMetadata(
            title: "Ordered Videos",
            input: input,
            videoInputReceipts: [orderedFirst.receipt, orderedSecond.receipt],
            requestedRunOptions: orderedRequested,
            resolvedRunPlan: orderedPlan
        )
        XCTAssertNoThrow(try ProjectArtifactValidator.test_validateControlledInputBinding(
            metadata: orderedMetadata,
            expectedInput: expected,
            paths: paths
        ))
        XCTAssertThrowsError(try ProjectArtifactValidator.test_validateControlledInputBinding(
            metadata: orderedMetadata,
            expectedInput: .videoFiles([secondExternal, firstExternal]),
            paths: paths
        ))

        let symlink = externalRoot.appendingPathComponent("second-link.mov")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: secondExternal)
        XCTAssertThrowsError(try ProjectArtifactValidator.test_validateControlledInputBinding(
            metadata: metadata,
            expectedInput: .videoFiles([firstExternal, symlink]),
            paths: paths
        ))

        let hardlink = externalRoot.appendingPathComponent("second-hardlink.mov")
        XCTAssertEqual(link(secondExternal.path, hardlink.path), 0)
        XCTAssertThrowsError(try ProjectArtifactValidator.test_validateControlledInputBinding(
            metadata: metadata,
            expectedInput: .videoFiles([firstExternal, secondExternal]),
            paths: paths
        ))
    }

    func testFinishedRawBindingRejectsJPEGBytesClaimedAsControlledPNG() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(
            root: root.appendingPathComponent("Raw.easysplatproj", isDirectory: true)
        )
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(
            at: paths.importedPhotosURL,
            withIntermediateDirectories: true
        )
        let externalFolder = root.appendingPathComponent("External", isDirectory: true)
        try FileManager.default.createDirectory(
            at: externalFolder,
            withIntermediateDirectories: true
        )
        let source = externalFolder.appendingPathComponent("capture.dng")
        try TestFileBuilder.writeMinimalRawDNG(to: source)
        let controlled = paths.importedPhotosURL.appendingPathComponent("photo-0000.png")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: controlled,
            size: 16,
            value: 96,
            utType: .jpeg
        ))
        try setPrivateMode(controlled)
        let sourceSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber
        ).int64Value
        let controlledSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: controlled.path)[.size] as? NSNumber
        ).int64Value
        let sourceSHA256 = try GeometryArtifactStore.sha256(of: source)
        let receipt = PhotoInputReceipt(
            projectRelativePath: "Originals/Photos/photo-0000.png",
            safeDisplayName: "capture.dng",
            byteCount: controlledSize,
            sha256: try GeometryArtifactStore.sha256(of: controlled),
            pixelWidth: 16,
            pixelHeight: 16,
            orientation: 1,
            typeIdentifier: UTType.png.identifier,
            source: PhotoSourceProvenance(
                byteCount: sourceSize,
                sha256: sourceSHA256,
                typeIdentifier: "com.adobe.raw-image"
            ),
            importMode: .rawDevelopment(RawDevelopmentEvidence(
                decoderIdentifier: RawPhotoDecoder.decoderIdentifier,
                decoderVersion: "fixture-1",
                settings: .production(maximumPixelDimension: 4_096),
                nativePixelWidth: 256,
                nativePixelHeight: 256,
                sourceOrientation: 1
            )),
            analysisEvidence: TestFileBuilder.photoAnalysisEvidence(
                sourceSHA256: sourceSHA256
            ),
            retainedRank: 0
        )
        let input = InputSpec.photos(folder: "Originals/Photos")
        let requested = RequestedRunOptions(
            detailProfile: .fast,
            inputOrdering: .unordered
        )
        let plan = RunPlanResolver.resolve(
            requestedOptions: requested,
            input: input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: DevelopmentOverrides(benchmarkSeed: 42)
        )
        let metadata = ProjectMetadata(
            title: "Raw",
            input: input,
            photoInputReceipts: [receipt],
            requestedRunOptions: requested,
            resolvedRunPlan: plan
        )

        XCTAssertThrowsError(try ProjectArtifactValidator.test_validateControlledInputBinding(
            metadata: metadata,
            expectedInput: .photoFolder(externalFolder),
            paths: paths
        ))
    }

    func testFinishedMixedBindingAcceptsExplicitEmptyPhotoProjection() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(
            root: root.appendingPathComponent("Mixed.easysplatproj", isDirectory: true)
        )
        let bytes = Data("receipt-bound-mixed-video".utf8)
        let video = try TestFileBuilder.writeControlledVideoReceipt(
            paths: paths,
            bytes: bytes,
            safeDisplayName: "capture.mov",
            clipGroupID: "video_sha256_\(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())"
        )
        try FileManager.default.createDirectory(
            at: paths.importedPhotosURL,
            withIntermediateDirectories: true
        )
        let externalVideo = root.appendingPathComponent("capture.mov")
        try bytes.write(to: externalVideo)
        let externalPhotos = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: externalPhotos, withIntermediateDirectories: true)
        try Data("not an image".utf8).write(
            to: externalPhotos.appendingPathComponent("README.txt")
        )
        let input = InputSpec.mixed(
            videos: [video.receipt.projectRelativePath],
            photosFolder: "Originals/Photos"
        )
        let requested = RequestedRunOptions(detailProfile: .fast)
        let plan = RunPlanResolver.resolve(
            requestedOptions: requested,
            input: input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: DevelopmentOverrides(benchmarkSeed: 42)
        )
        let metadata = ProjectMetadata(
            title: "Mixed",
            input: input,
            videoInputReceipts: [video.receipt],
            photoInputReceipts: [],
            requestedRunOptions: requested,
            resolvedRunPlan: plan
        )

        XCTAssertNoThrow(try ProjectArtifactValidator.test_validateControlledInputBinding(
            metadata: metadata,
            expectedInput: .mixed(
                videoFiles: [externalVideo],
                photoFolder: externalPhotos
            ),
            paths: paths
        ))

        try Data("stale photo selection evidence".utf8).write(
            to: paths.photoSelectionArtifactURL,
            options: .atomic
        )
        try setPrivateMode(paths.photoSelectionArtifactURL)
        XCTAssertThrowsError(try ProjectArtifactValidator.test_validateControlledInputBinding(
            metadata: metadata,
            expectedInput: .mixed(
                videoFiles: [externalVideo],
                photoFolder: externalPhotos
            ),
            paths: paths
        ))
        try FileManager.default.removeItem(at: paths.photoSelectionArtifactURL)

        try FileManager.default.createDirectory(
            at: paths.originalsURL
                .appendingPathComponent("Unexpected", isDirectory: true)
                .appendingPathComponent("Empty", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertThrowsError(try ProjectArtifactValidator.test_validateControlledInputBinding(
            metadata: metadata,
            expectedInput: .mixed(
                videoFiles: [externalVideo],
                photoFolder: externalPhotos
            ),
            paths: paths
        ))
    }

    func testFinishedMixedBindingAcceptsReceiptBoundVideoAndPhotoProjection() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(
            root: root.appendingPathComponent("MixedPhotos.easysplatproj", isDirectory: true)
        )
        let videoBytes = Data("receipt-bound-mixed-video-with-photo".utf8)
        let video = try TestFileBuilder.writeControlledVideoReceipt(
            paths: paths,
            bytes: videoBytes,
            safeDisplayName: "capture.mov",
            clipGroupID: "video_sha256_\(SHA256.hash(data: videoBytes).map { String(format: "%02x", $0) }.joined())"
        )
        let externalVideo = root.appendingPathComponent("capture.mov")
        try videoBytes.write(to: externalVideo)

        let externalPhotos = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: externalPhotos, withIntermediateDirectories: true)
        let externalPhoto = externalPhotos.appendingPathComponent("source.jpg")
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: externalPhoto,
            size: 16,
            value: 192,
            utType: .jpeg
        ))
        try FileManager.default.createDirectory(
            at: paths.importedPhotosURL,
            withIntermediateDirectories: true
        )
        let controlledPhoto = paths.importedPhotosURL.appendingPathComponent("photo-0000.jpg")
        try FileManager.default.copyItem(at: externalPhoto, to: controlledPhoto)
        XCTAssertEqual(chmod(controlledPhoto.path, 0o600), 0)
        let photoByteCount = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: controlledPhoto.path)[.size] as? NSNumber
        ).int64Value
        let photoSHA256 = try GeometryArtifactStore.sha256(of: controlledPhoto)
        let photoReceipt = PhotoInputReceipt(
            projectRelativePath: "Originals/Photos/photo-0000.jpg",
            safeDisplayName: "source.jpg",
            byteCount: photoByteCount,
            sha256: photoSHA256,
            pixelWidth: 16,
            pixelHeight: 16,
            orientation: 1,
            typeIdentifier: "public.jpeg",
            analysisEvidence: TestFileBuilder.photoAnalysisEvidence(
                sourceSHA256: photoSHA256
            ),
            retainedRank: 0
        )
        let input = InputSpec.mixed(
            videos: [video.receipt.projectRelativePath],
            photosFolder: "Originals/Photos"
        )
        let requested = RequestedRunOptions(detailProfile: .fast)
        let plan = RunPlanResolver.resolve(
            requestedOptions: requested,
            input: input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: DevelopmentOverrides(benchmarkSeed: 42)
        )
        var metadata = ProjectMetadata(
            title: "Mixed Photos",
            input: input,
            videoInputReceipts: [video.receipt],
            photoInputReceipts: [photoReceipt],
            requestedRunOptions: requested,
            resolvedRunPlan: plan
        )
        let rankedPhotoEvidence = try PhotoDiversitySelector.rank(
            [photoReceipt.analysisEvidence],
            targetCount: 1
        )
        let photoSelectionArtifact = PhotoSelectionArtifact(
            strategy: .visualDiversity,
            analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
            analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256,
            selectorPolicyVersion: PhotoDiversitySelector.selectorPolicyVersion,
            selectorPolicySHA256: PhotoDiversitySelector.selectorPolicySHA256,
            inputOrdering: plan.inputOrdering,
            requestedPhotoSelection: plan.photoSelection,
            admissionCapacity: 1,
            discoveredCount: 1,
            acceptedCount: 1,
            unreadableCount: 0,
            exactDuplicateCount: 0,
            companionDuplicateCount: 0,
            candidates: [
                PhotoSelectionCandidateArtifact(
                    admissionOrdinal: 0,
                    evidence: photoReceipt.analysisEvidence,
                    retainedRank: photoReceipt.retainedRank
                ),
            ],
            retainedSourceSHA256s: rankedPhotoEvidence.map(\.sourceSHA256),
            canonicalRetainedSourceSHA256s: [photoReceipt.source.sha256]
        )
        let photoSelectionFile = try PhotoSelectionArtifactStore.save(
            photoSelectionArtifact,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths
        )
        metadata.photoSelectionReceipt = PhotoSelectionReceipt(
            projectRelativePath: PhotoSelectionReceipt.projectRelativePath,
            byteCount: photoSelectionFile.byteCount,
            sha256: photoSelectionFile.sha256,
            artifactSchemaVersion: photoSelectionArtifact.schemaVersion,
            analysisRecipeVersion: photoSelectionArtifact.analysisRecipeVersion,
            analysisRecipeSHA256: photoSelectionArtifact.analysisRecipeSHA256,
            selectorPolicyVersion: photoSelectionArtifact.selectorPolicyVersion,
            selectorPolicySHA256: photoSelectionArtifact.selectorPolicySHA256
        )
        let encodedMetadata = String(
            decoding: try JSONEncoder().encode(metadata),
            as: UTF8.self
        )
        XCTAssertFalse(encodedMetadata.contains(externalVideo.path))
        XCTAssertFalse(encodedMetadata.contains(externalPhotos.path))

        XCTAssertNoThrow(try ProjectArtifactValidator.test_validateControlledInputBinding(
            metadata: metadata,
            expectedInput: .mixed(
                videoFiles: [externalVideo],
                photoFolder: externalPhotos
            ),
            paths: paths
        ))
    }

    func testExpectedInputSnapshotBindsVideoOrderDigestAndIdentity() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.mov")
        let second = root.appendingPathComponent("second.mov")
        try Data("first-video".utf8).write(to: first)
        try Data("second-video".utf8).write(to: second)

        let initial = try ProjectArtifactValidator.captureExpectedInputSnapshot(
            .videoFiles([first, second])
        )
        XCTAssertEqual(
            initial,
            try ProjectArtifactValidator.captureExpectedInputSnapshot(
                .videoFiles([first, second])
            )
        )
        XCTAssertNotEqual(
            initial,
            try ProjectArtifactValidator.captureExpectedInputSnapshot(
                .videoFiles([second, first])
            )
        )

        let replacement = root.appendingPathComponent("replacement.mov")
        try Data("first-video".utf8).write(to: replacement)
        XCTAssertEqual(rename(replacement.path, first.path), 0)
        XCTAssertNotEqual(
            initial,
            try ProjectArtifactValidator.captureExpectedInputSnapshot(
                .videoFiles([first, second])
            )
        )
    }

    func testExpectedInputSnapshotContinuityGateRejectsIdenticalByteReplacement() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("source.mov")
        let bytes = Data("same-video-bytes".utf8)
        try bytes.write(to: video)
        let expectedInput = FinishedProjectExpectedInput.videoFiles([video])
        let initial = try ProjectArtifactValidator.captureExpectedInputSnapshot(expectedInput)

        XCTAssertNoThrow(
            try ProjectArtifactValidator.test_requireExpectedInputSnapshotUnchanged(
                initial,
                expectedInput: expectedInput
            )
        )

        let replacement = root.appendingPathComponent("replacement.mov")
        try bytes.write(to: replacement)
        XCTAssertEqual(rename(replacement.path, video.path), 0)
        XCTAssertThrowsError(
            try ProjectArtifactValidator.test_requireExpectedInputSnapshotUnchanged(
                initial,
                expectedInput: expectedInput
            )
        )
    }

    func testExpectedPhotoSnapshotRejectsHiddenAliasesSpecialsAndSubtrees() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)

        let harmless = root.appendingPathComponent("harmless", isDirectory: true)
        try FileManager.default.createDirectory(at: harmless, withIntermediateDirectories: true)
        try Data("metadata".utf8).write(
            to: harmless.appendingPathComponent(".DS_Store")
        )
        XCTAssertNoThrow(
            try ProjectArtifactValidator.captureExpectedInputSnapshot(.photoFolder(harmless))
        )

        let symlinkFolder = root.appendingPathComponent("symlink", isDirectory: true)
        try FileManager.default.createDirectory(
            at: symlinkFolder,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkFolder.appendingPathComponent(".alias"),
            withDestinationURL: outside
        )
        XCTAssertThrowsError(
            try ProjectArtifactValidator.captureExpectedInputSnapshot(.photoFolder(symlinkFolder))
        )

        let hardlinkFolder = root.appendingPathComponent("hardlink", isDirectory: true)
        try FileManager.default.createDirectory(
            at: hardlinkFolder,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(
            link(outside.path, hardlinkFolder.appendingPathComponent(".alias").path),
            0
        )
        XCTAssertThrowsError(
            try ProjectArtifactValidator.captureExpectedInputSnapshot(.photoFolder(hardlinkFolder))
        )

        let specialFolder = root.appendingPathComponent("special", isDirectory: true)
        try FileManager.default.createDirectory(
            at: specialFolder,
            withIntermediateDirectories: true
        )
        XCTAssertEqual(
            Darwin.mkfifo(specialFolder.appendingPathComponent(".pipe").path, 0o600),
            0
        )
        XCTAssertThrowsError(
            try ProjectArtifactValidator.captureExpectedInputSnapshot(.photoFolder(specialFolder))
        )

        let subtreeFolder = root.appendingPathComponent("subtree", isDirectory: true)
        let hiddenSubtree = subtreeFolder.appendingPathComponent(".cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: hiddenSubtree,
            withIntermediateDirectories: true
        )
        try Data("nested".utf8).write(
            to: hiddenSubtree.appendingPathComponent("nested.txt")
        )
        XCTAssertThrowsError(
            try ProjectArtifactValidator.captureExpectedInputSnapshot(.photoFolder(subtreeFolder))
        )
    }

    func testExpectedPhotoSnapshotBindsAcceptedPhotosAndFullTreeIdentity() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        let nested = photos.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: nested.appendingPathComponent("photo.jpg"),
            size: 16,
            value: 128,
            utType: .jpeg
        ))
        let metadata = photos.appendingPathComponent(".DS_Store")
        let metadataBytes = Data("ordinary hidden metadata".utf8)
        try metadataBytes.write(to: metadata)
        let initial = try ProjectArtifactValidator.captureExpectedInputSnapshot(
            .photoFolder(photos)
        )

        let replacement = photos.appendingPathComponent("replacement")
        try metadataBytes.write(to: replacement)
        XCTAssertEqual(rename(replacement.path, metadata.path), 0)
        XCTAssertNotEqual(
            initial,
            try ProjectArtifactValidator.captureExpectedInputSnapshot(.photoFolder(photos))
        )
    }

    func testFinishedVideoSelectionPolicyRederivesExactAttainableOrigins() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("selection.mov")
        let times = (0..<31).map { Double($0) * 0.2 }
        do {
            try await TestVideoBuilder.writeH264(
                to: video,
                times: times,
                levels: times.indices.map { UInt8(32 + ($0 * 17) % 190) },
                expectedFrameRate: 5
            )
        } catch TestVideoBuilder.FixtureError.unsupportedCodec(let reason) {
            throw XCTSkip(reason)
        }
        let requested = RequestedRunOptions(detailProfile: .balanced)
        let plan = RunPlanResolver.resolve(
            requestedOptions: requested,
            input: .video(files: [video.path]),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: DevelopmentOverrides(benchmarkSeed: 42)
        )
        let firstOutput = root.appendingPathComponent("first", isDirectory: true)
        let first = try await ProjectArtifactValidator.test_independentlySelectedVideoOrigins(
            from: video,
            plan: plan,
            detail: .balanced,
            outputDirectory: firstOutput
        )
        XCTAssertGreaterThan(first.count, 2)

        let secondOutput = root.appendingPathComponent("second", isDirectory: true)
        let second = try await ProjectArtifactValidator.test_independentlySelectedVideoOrigins(
            from: video,
            plan: plan,
            detail: .balanced,
            outputDirectory: secondOutput
        )
        XCTAssertEqual(second, first)
    }

    func testFinishedGeometryTimestampsRequireExactSelectedManifestValues() throws {
        let photo = PipelineRunner.SelectedFrameMapping(
            outputFileName: "frame_000000.jpg",
            groupId: "photos",
            isVideo: false
        )
        XCTAssertNoThrow(
            try ProjectArtifactValidator.test_requireExactOrderedTimestamps(
                [photo],
                geometryTimestamps: [nil]
            )
        )
        XCTAssertThrowsError(
            try ProjectArtifactValidator.test_requireExactOrderedTimestamps(
                [photo],
                geometryTimestamps: [1]
            )
        )

        let videos = (0..<2).map { index in
            PipelineRunner.SelectedFrameMapping(
                outputFileName: String(format: "frame_%06d.jpg", index),
                groupId: "video_000",
                isVideo: true,
                timestampSeconds: Double(index)
            )
        }
        XCTAssertNoThrow(
            try ProjectArtifactValidator.test_requireExactOrderedTimestamps(
                videos,
                geometryTimestamps: [0, 1]
            )
        )
        XCTAssertThrowsError(
            try ProjectArtifactValidator.test_requireExactOrderedTimestamps(
                videos,
                geometryTimestamps: [0, 2]
            )
        )
    }

    func testFinishedPhotoUseAllCannotExceedResolvedBudget() throws {
        let requested = RequestedRunOptions(
            capturePath: .orbit,
            detailProfile: .fast,
            photoSelection: .useAllValidPhotos
        )
        let plan = RunPlanResolver.resolve(
            requestedOptions: requested,
            input: .photos(folder: "/tmp/photos"),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: DevelopmentOverrides(benchmarkSeed: 42)
        )
        XCTAssertEqual(
            try ProjectArtifactValidator.test_photoSelectionTarget(
                validCount: plan.keyframeBudget,
                plan: plan
            ),
            plan.keyframeBudget
        )
        XCTAssertThrowsError(
            try ProjectArtifactValidator.test_photoSelectionTarget(
                validCount: plan.keyframeBudget + 1,
                plan: plan
            )
        )
    }

    func testValidateFinishedProjectRejectsMixedInputAtIsolatedBoundary() async throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var metadata = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        let videoBytes = Data("test-video".utf8)
        let videoDigest = SHA256.hash(data: videoBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let video = try TestFileBuilder.writeControlledVideoReceipt(
            paths: fixture.paths,
            bytes: videoBytes,
            clipGroupID: "video_sha256_\(videoDigest)"
        )
        metadata.input = .mixed(
            videos: [video.receipt.projectRelativePath],
            photosFolder: "Originals/Photos"
        )
        metadata.videoInputReceipts = [video.receipt]
        try ProjectMetadataStore.save(metadata, to: fixture.paths.metadataURL)
        try setPrivateMode(fixture.paths.metadataURL)

        await XCTAssertThrowsErrorAsync {
            _ = try await ProjectArtifactValidator.validateFinishedProject(
                at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
                context: fixture.validationContext,
                independentlyRederiveVideoFrames: true
            )
        }
    }

    func testValidateFinishedProjectRejectsMissingOrMismatchedSidecars() throws {
        do {
            let fixture = try makeFinishedProjectFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try FileManager.default.removeItem(at: fixture.paths.geometryManifestURL)

            XCTAssertThrowsError(
                try ProjectArtifactValidator.validateFinishedProject(
                    at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
                    context: fixture.validationContext
                )
            )
        }

        do {
            let fixture = try makeFinishedProjectFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            var mismatched = fixture.training
            mismatched.geometryDigest = String(repeating: "0", count: 64)
            mismatched.datasetDerivation.datasetGeometryDigest = mismatched.geometryDigest
            try TrainingArtifactStore.save(
                mismatched,
                to: fixture.paths.trainingManifestURL,
                projectPaths: fixture.paths
            )
            try setPrivateMode(fixture.paths.trainingManifestURL)

            XCTAssertThrowsError(
                try ProjectArtifactValidator.validateFinishedProject(
                    at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
                    context: fixture.validationContext
                )
            )
        }
    }

    func testValidateFinishedProjectRejectsWrongCanonicalBindingDigestOrMode() throws {
        do {
            let fixture = try makeFinishedProjectFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            var training = try TrainingArtifactStore.load(
                from: fixture.paths.trainingManifestURL,
                projectPaths: fixture.paths
            )
            training.outputPath = "Output/other.ply"
            try FileManager.default.copyItem(
                at: fixture.output,
                to: fixture.paths.outputURL.appendingPathComponent("other.ply")
            )
            try JSONEncoder().encode(training).write(
                to: fixture.paths.trainingManifestURL,
                options: .atomic
            )
            try setPrivateMode(fixture.paths.trainingManifestURL)

            XCTAssertThrowsError(
                try ProjectArtifactValidator.validateFinishedProject(
                    at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
                    context: fixture.validationContext
                )
            )
        }

        do {
            let fixture = try makeFinishedProjectFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try mutateFirstVertexCoordinate(at: fixture.output)

            XCTAssertThrowsError(
                try ProjectArtifactValidator.validateFinishedProject(
                    at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
                    context: fixture.validationContext
                )
            )
        }

        for unsafeMode: NSNumber in [0o664, 0o744, 0o444] {
            let fixture = try makeFinishedProjectFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            try FileManager.default.setAttributes(
                [.posixPermissions: unsafeMode],
                ofItemAtPath: fixture.output.path
            )

            XCTAssertThrowsError(
                try ProjectArtifactValidator.validateFinishedProject(
                    at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
                    context: fixture.validationContext
                ),
                "Expected unsafe artifact mode \(String(unsafeMode.intValue, radix: 8)) to be rejected."
            )
        }
    }

    func testValidateFinishedProjectRejectsInputAndResolvedTrainingMismatch() throws {
        do {
            let fixture = try makeFinishedProjectFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let otherInput = fixture.root.appendingPathComponent("other-input", isDirectory: true)
            try FileManager.default.createDirectory(at: otherInput, withIntermediateDirectories: true)

            XCTAssertThrowsError(
                try ProjectArtifactValidator.validateFinishedProject(
                    at: fixture.paths.root,
            expectedInput: .photoFolder(otherInput),
                    context: fixture.validationContext
                )
            )
        }

        do {
            let fixture = try makeFinishedProjectFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            var metadata = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
            metadata.resolvedRunPlan?.runSeed += 1
            try ProjectMetadataStore.save(metadata, to: fixture.paths.metadataURL)
            try setPrivateMode(fixture.paths.metadataURL)

            XCTAssertThrowsError(
                try ProjectArtifactValidator.validateFinishedProject(
                    at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
                    context: fixture.validationContext
                )
            )
        }
    }

    func testValidateFinishedProjectRejectsInputBytesThatWereNotImported() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("different source fixture".utf8).write(
            to: fixture.input.appendingPathComponent("source-0.jpg")
        )

        XCTAssertThrowsError(
            try ProjectArtifactValidator.validateFinishedProject(
                at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
                context: fixture.validationContext
            )
        )
    }

    func testValidateFinishedProjectRejectsMissingSelectedFrameLineageManifest() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.paths.framesSelectedManifestURL.path),
            "The valid fixture must contain authenticated selected-frame lineage."
        )
        try FileManager.default.removeItem(at: fixture.paths.framesSelectedManifestURL)
        XCTAssertThrowsError(
            try ProjectArtifactValidator.validateFinishedProject(
                at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
                context: fixture.validationContext
            )
        )
    }

    func testValidateFinishedProjectRejectsSelectedFrameSourceSubstitution() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let data = try Data(contentsOf: fixture.paths.framesSelectedManifestURL)
        var records = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        records[0]["sourceProjectRelativePath"] = "Originals/Photos/source-1.jpg"
        try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]).write(
            to: fixture.paths.framesSelectedManifestURL,
            options: .atomic
        )
        try setPrivateMode(fixture.paths.framesSelectedManifestURL)

        XCTAssertThrowsError(
            try ProjectArtifactValidator.validateFinishedProject(
                at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
                context: fixture.validationContext
            )
        )
    }

    func testValidateFinishedProjectRejectsForgedSelectedFrameNormalization() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let data = try Data(contentsOf: fixture.paths.framesSelectedManifestURL)
        var records = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        )
        var normalization = try XCTUnwrap(records[0]["normalization"] as? [String: Any])
        normalization["maximumPixelDimension"] = fixture.plan.maximumImageDimension - 1
        records[0]["normalization"] = normalization
        try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]).write(
            to: fixture.paths.framesSelectedManifestURL,
            options: .atomic
        )
        try setPrivateMode(fixture.paths.framesSelectedManifestURL)

        XCTAssertThrowsError(
            try ProjectArtifactValidator.validateFinishedProject(
                at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
                context: fixture.validationContext
            )
        )
    }

    func testValidateFinishedProjectRecomputesTrainingDatasetIdentity() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var metadata = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        var forgedTraining = fixture.training
        forgedTraining.inputDigest = String(repeating: "a", count: 64)
        forgedTraining.geometryDigest = String(repeating: "b", count: 64)
        forgedTraining.datasetDerivation.datasetInputDigest = forgedTraining.inputDigest
        forgedTraining.datasetDerivation.datasetGeometryDigest = forgedTraining.geometryDigest
        try TrainingArtifactStore.persist(
            forgedTraining,
            paths: fixture.paths
        )
        metadata.state = PipelineState(stage: .done, lastError: nil)
        try ProjectMetadataStore.save(metadata, to: fixture.paths.metadataURL)
        try setPrivateMode(fixture.paths.trainingManifestURL)
        try setPrivateMode(fixture.paths.metadataURL)

        XCTAssertThrowsError(
            try ProjectArtifactValidator.validateFinishedProject(
                at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
                context: fixture.validationContext
            )
        )
    }

    func testValidateFinishedProjectRejectsCoherentlyRewrittenDirectDatasetImage() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let name = try XCTUnwrap(fixture.geometry.orderedImageNames.first)
        let retained = fixture.paths.trainingURL.appendingPathComponent(
            "msplat_dataset/images/\(name)"
        )
        XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
            url: retained,
            size: 16,
            value: 1,
            utType: .jpeg
        ))
        let identity = try MsplatDatasetIdentity.compute(
            imageDirectory: fixture.paths.trainingURL.appendingPathComponent(
                "msplat_dataset/images"
            ),
            sparseDirectory: fixture.paths.trainingURL.appendingPathComponent(
                "msplat_dataset/sparse/0"
            )
        )
        var metadata = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        var forged = fixture.training
        forged.inputDigest = identity.inputDigest
        forged.geometryDigest = identity.geometryDigest
        forged.datasetDerivation.datasetInputDigest = identity.inputDigest
        forged.datasetDerivation.datasetGeometryDigest = identity.geometryDigest
        try TrainingArtifactStore.persist(forged, paths: fixture.paths)
        metadata.state = PipelineState(stage: .done, lastError: nil)
        try ProjectMetadataStore.save(metadata, to: fixture.paths.metadataURL)
        try setPrivateMode(fixture.paths.trainingManifestURL)
        try setPrivateMode(fixture.paths.metadataURL)
        try setPrivateMode(retained)

        XCTAssertThrowsError(
            try ProjectArtifactValidator.validateFinishedProject(
                at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
                context: fixture.validationContext
            )
        )
    }

    func testValidateFinishedProjectRejectsForgedDatasetDerivationReceipt() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var metadata = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        var forged = fixture.training
        forged.datasetDerivation.sourceGeometryManifestSHA256 = String(
            repeating: "f",
            count: 64
        )
        try TrainingArtifactStore.persist(forged, paths: fixture.paths)
        metadata.state = PipelineState(stage: .done, lastError: nil)
        try ProjectMetadataStore.save(metadata, to: fixture.paths.metadataURL)
        try setPrivateMode(fixture.paths.trainingManifestURL)
        try setPrivateMode(fixture.paths.metadataURL)

        XCTAssertThrowsError(
            try ProjectArtifactValidator.validateFinishedProject(
                at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
                context: fixture.validationContext
            )
        )
    }

    func testFinishedOrientationMustMatchDeterministicEstimatorStatusAndDirection() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let measured = try ColmapResidualAnalyzer.analyze(
            modelDirectory: fixture.paths.colmapSparseURL.appendingPathComponent("0")
        )

        var wrongDirection = fixture.geometry
        wrongDirection.canonicalOrientation.canonicalOpeningViewDirection = CanonicalDirection(
            x: 1,
            y: 0,
            z: 0
        )
        XCTAssertThrowsError(
            try ProjectArtifactValidator.test_requireCanonicalOrientationBinding(
                geometry: wrongDirection,
                measured: measured,
                plan: fixture.plan
            )
        )

        var wrongStatus = fixture.geometry
        wrongStatus.canonicalOrientation.status = .axisAlignedSignUnverified
        wrongStatus.canonicalOrientation.method = .cameraRightNullspace
        wrongStatus.canonicalOrientation.sourceToCanonicalQuaternionWXYZ = CanonicalQuaternionWXYZ(
            w: 1,
            x: 0,
            y: 0,
            z: 0
        )
        XCTAssertThrowsError(
            try ProjectArtifactValidator.test_requireCanonicalOrientationBinding(
                geometry: wrongStatus,
                measured: measured,
                plan: fixture.plan
            )
        )
    }

    func testFinishedCameraModelAndGroupingMustMatchResolvedPlan() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.paths.colmapSparseURL.appendingPathComponent("0")
        let measured = try ColmapResidualAnalyzer.analyze(modelDirectory: model)
        XCTAssertNoThrow(
            try ProjectArtifactValidator.test_requireCanonicalCameraBinding(
                geometry: fixture.geometry,
                measured: measured,
                plan: fixture.plan,
                detailProfile: fixture.metadata.requestedRunOptions.detailProfile,
                selectedImages: fixture.geometry.orderedImageNames.map {
                    fixture.paths.framesSelectedURL.appendingPathComponent($0)
                }
            )
        )

        var wrongLensPlan = fixture.plan
        wrongLensPlan.lensProjection = .fisheye
        XCTAssertThrowsError(
            try ProjectArtifactValidator.test_requireCanonicalCameraBinding(
                geometry: fixture.geometry,
                measured: measured,
                plan: wrongLensPlan,
                detailProfile: fixture.metadata.requestedRunOptions.detailProfile,
                selectedImages: fixture.geometry.orderedImageNames.map {
                    fixture.paths.framesSelectedURL.appendingPathComponent($0)
                }
            )
        )

        let camerasURL = model.appendingPathComponent("cameras.txt")
        try Data(
            "1 SIMPLE_RADIAL 640 480 500 320 240 0\n"
                .appending("2 SIMPLE_RADIAL 640 480 500 320 240 0\n")
                .utf8
        ).write(to: camerasURL, options: .atomic)
        let extraCameraMeasured = try ColmapResidualAnalyzer.analyze(modelDirectory: model)
        XCTAssertThrowsError(
            try ProjectArtifactValidator.test_requireCanonicalCameraBinding(
                geometry: fixture.geometry,
                measured: extraCameraMeasured,
                plan: fixture.plan,
                detailProfile: fixture.metadata.requestedRunOptions.detailProfile,
                selectedImages: fixture.geometry.orderedImageNames.map {
                    fixture.paths.framesSelectedURL.appendingPathComponent($0)
                }
            )
        )

        var mixedPlan = fixture.plan
        mixedPlan.cameraGrouping = .mixedCamerasOrLenses
        var mixedGeometry = fixture.geometry
        mixedGeometry.cameraGrouping = .mixedCamerasOrLenses
        mixedGeometry.cameraGroupingReceipt = ColmapCameraGroupingReceipt(
            mode: .preserveExisting,
            cameraCountBefore: 3,
            cameraCountAfter: 3,
            groupedVideoSourceCount: 0,
            groups: []
        )
        XCTAssertThrowsError(
            try ProjectArtifactValidator.test_requireCanonicalCameraBinding(
                geometry: mixedGeometry,
                measured: measured,
                plan: mixedPlan,
                detailProfile: fixture.metadata.requestedRunOptions.detailProfile,
                selectedImages: fixture.geometry.orderedImageNames.map {
                    fixture.paths.framesSelectedURL.appendingPathComponent($0)
                }
            )
        )
    }

    func testFinishedClassicalPhotoGroupingAcceptsCOLMAPExifEquivalenceClasses() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let selected = fixture.root.appendingPathComponent(
            "SyntheticSelected",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let imageNames = [
            "wide-a.jpg",
            "wide-b.jpg",
            "tele.jpg",
            "wide-different-size.jpg",
        ]
        let imageURLs = imageNames.map { selected.appendingPathComponent($0) }
        try writeCameraMetadataJPEG(at: imageURLs[0], focalLength35mm: 23)
        try writeCameraMetadataJPEG(at: imageURLs[1], focalLength35mm: 23)
        try writeCameraMetadataJPEG(at: imageURLs[2], focalLength35mm: 46)
        try writeCameraMetadataJPEG(
            at: imageURLs[3],
            focalLength35mm: 23,
            width: 20,
            height: 15
        )

        let focalLengths = try imageURLs.map { url -> Int in
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = try XCTUnwrap(
                CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            )
            let exif = try XCTUnwrap(
                properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            )
            return try XCTUnwrap(
                (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.intValue
            )
        }
        XCTAssertEqual(focalLengths, [23, 23, 46, 23])

        var plan = fixture.plan
        plan.cameraGrouping = .mixedCamerasOrLenses
        var geometry = fixture.geometry
        geometry.cameraGrouping = .mixedCamerasOrLenses
        geometry.cameraGroupingReceipt = ColmapCameraGroupingReceipt(
            mode: .preserveExisting,
            cameraCountBefore: 3,
            cameraCountAfter: 3,
            groupedVideoSourceCount: 0,
            groups: []
        )
        let measured = makeCameraMeasurement(
            imageNames: imageNames,
            cameraIDsByImageName: [
                imageNames[0]: 97,
                imageNames[1]: 97,
                imageNames[2]: 41,
                imageNames[3]: 83,
            ]
        )

        XCTAssertNoThrow(
            try ProjectArtifactValidator.test_requireCanonicalCameraBinding(
                geometry: geometry,
                measured: measured,
                plan: plan,
                detailProfile: fixture.metadata.requestedRunOptions.detailProfile,
                selectedImages: imageURLs
            )
        )

        let underGrouped = makeCameraMeasurement(
            imageNames: imageNames,
            cameraIDsByImageName: Dictionary(
                uniqueKeysWithValues: imageNames.map { ($0, 41) }
            )
        )
        XCTAssertThrowsError(
            try ProjectArtifactValidator.test_requireCanonicalCameraBinding(
                geometry: geometry,
                measured: underGrouped,
                plan: plan,
                detailProfile: fixture.metadata.requestedRunOptions.detailProfile,
                selectedImages: imageURLs
            )
        )

        let overSplit = makeCameraMeasurement(
            imageNames: imageNames,
            cameraIDsByImageName: [
                imageNames[0]: 1,
                imageNames[1]: 2,
                imageNames[2]: 3,
                imageNames[3]: 4,
            ]
        )
        XCTAssertThrowsError(
            try ProjectArtifactValidator.test_requireCanonicalCameraBinding(
                geometry: geometry,
                measured: overSplit,
                plan: plan,
                detailProfile: fixture.metadata.requestedRunOptions.detailProfile,
                selectedImages: imageURLs
            )
        )
    }

    func testFinishedCameraGroupingMatchesMissingExifAndRouteSemantics() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let selected = fixture.root.appendingPathComponent(
            "SyntheticRouteSelected",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        let imageNames = ["first.jpg", "second.jpg"]
        let imageURLs = imageNames.map { selected.appendingPathComponent($0) }
        for (index, image) in imageURLs.enumerated() {
            XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
                url: image,
                size: 16,
                value: UInt8(80 + index),
                utType: .jpeg
            ))
        }

        var mixedPlan = fixture.plan
        mixedPlan.cameraGrouping = .mixedCamerasOrLenses
        var mixedGeometry = fixture.geometry
        mixedGeometry.cameraGrouping = .mixedCamerasOrLenses
        mixedGeometry.cameraGroupingReceipt = ColmapCameraGroupingReceipt(
            mode: .preserveExisting,
            cameraCountBefore: 2,
            cameraCountAfter: 2,
            groupedVideoSourceCount: 0,
            groups: []
        )
        let perImage = makeCameraMeasurement(
            imageNames: imageNames,
            cameraIDsByImageName: [imageNames[0]: 9, imageNames[1]: 5]
        )
        XCTAssertNoThrow(
            try ProjectArtifactValidator.test_requireCanonicalCameraBinding(
                geometry: mixedGeometry,
                measured: perImage,
                plan: mixedPlan,
                detailProfile: fixture.metadata.requestedRunOptions.detailProfile,
                selectedImages: imageURLs
            )
        )
        let missingExifCollapsed = makeCameraMeasurement(
            imageNames: imageNames,
            cameraIDsByImageName: [imageNames[0]: 9, imageNames[1]: 9]
        )
        XCTAssertThrowsError(
            try ProjectArtifactValidator.test_requireCanonicalCameraBinding(
                geometry: mixedGeometry,
                measured: missingExifCollapsed,
                plan: mixedPlan,
                detailProfile: fixture.metadata.requestedRunOptions.detailProfile,
                selectedImages: imageURLs
            )
        )

        try writeCameraMetadataJPEG(at: imageURLs[0], focalLength35mm: 23)
        try writeCameraMetadataJPEG(at: imageURLs[1], focalLength35mm: 23)
        var da3Plan = mixedPlan
        da3Plan.geometryBackend = .da3
        XCTAssertNoThrow(
            try ProjectArtifactValidator.test_requireCanonicalCameraBinding(
                geometry: mixedGeometry,
                measured: missingExifCollapsed,
                plan: da3Plan,
                detailProfile: fixture.metadata.requestedRunOptions.detailProfile,
                selectedImages: imageURLs
            )
        )
        XCTAssertThrowsError(
            try ProjectArtifactValidator.test_requireCanonicalCameraBinding(
                geometry: mixedGeometry,
                measured: perImage,
                plan: da3Plan,
                detailProfile: fixture.metadata.requestedRunOptions.detailProfile,
                selectedImages: imageURLs
            )
        )

        var sharedPlan = mixedPlan
        sharedPlan.cameraGrouping = .sameCameraAndLens
        var sharedGeometry = mixedGeometry
        sharedGeometry.cameraGrouping = .sameCameraAndLens
        sharedGeometry.cameraGroupingReceipt = ColmapCameraGroupingReceipt(
            mode: .allSelectedImagesShared,
            cameraCountBefore: 1,
            cameraCountAfter: 1,
            groupedVideoSourceCount: 0,
            groups: [ColmapCameraGroupReceipt(
                sourceGroupID: "all-selected-images",
                memberCount: 2,
                canonicalCameraID: 9
            )]
        )
        try writeCameraMetadataJPEG(at: imageURLs[1], focalLength35mm: 46)
        XCTAssertNoThrow(
            try ProjectArtifactValidator.test_requireCanonicalCameraBinding(
                geometry: sharedGeometry,
                measured: missingExifCollapsed,
                plan: sharedPlan,
                detailProfile: fixture.metadata.requestedRunOptions.detailProfile,
                selectedImages: imageURLs
            )
        )
    }

    func testValidateFinishedProjectRejectsPlanNotResolvedFromReleaseHardware() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var metadata = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        metadata.resolvedRunPlan?.maximumImageDimension += 1
        try ProjectMetadataStore.save(metadata, to: fixture.paths.metadataURL)
        try setPrivateMode(fixture.paths.metadataURL)

        XCTAssertThrowsError(
            try ProjectArtifactValidator.validateFinishedProject(
                at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
                context: fixture.validationContext
            )
        )
    }

    func testValidateFinishedProjectAcceptsCadenceFallbackBoundToThePlannedRun() throws {
        let fixture = try makeFinishedProjectFixture(
            cadenceOverride: FinishedCadenceOverride(
                planned: .balancedGlobal,
                accepted: .frequentGlobal,
                trigger: .insufficientViewSupport
            )
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertNoThrow(
            try ProjectArtifactValidator.validateFinishedProject(
                at: fixture.paths.root,
                expectedInput: .photoFolder(fixture.input),
                context: fixture.validationContext
            )
        )
    }

    func testValidateFinishedProjectRejectsFallbackWithForgedPlannedCadence() throws {
        let fixture = try makeFinishedProjectFixture(
            cadenceOverride: FinishedCadenceOverride(
                planned: .balancedGlobal,
                accepted: .frequentGlobal,
                trigger: .insufficientViewSupport
            )
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var geometry = try GeometryArtifactStore.load(
            from: fixture.paths.geometryManifestURL,
            projectPaths: fixture.paths
        )
        geometry.mapping.plannedIncrementalCadence = .orderedFast
        try JSONEncoder().encode(geometry).write(
            to: fixture.paths.geometryManifestURL,
            options: .atomic
        )
        try setProjectArtifactMode(fixture.paths.geometryManifestURL)

        XCTAssertThrowsError(
            try ProjectArtifactValidator.validateFinishedProject(
                at: fixture.paths.root,
                expectedInput: .photoFolder(fixture.input),
                context: fixture.validationContext
            )
        )
    }

    func testValidateFinishedProjectRejectsMissingPairGraphEvidence() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.paths.pairGraphEvidenceURL)

        XCTAssertThrowsError(try ProjectArtifactValidator.validateFinishedProject(
            at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
            context: fixture.validationContext
        ))
    }

    func testValidateFinishedProjectRejectsPairEvidenceBoundToAnotherSeed() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var evidence = try PairGraphEvidenceStore.load(
            from: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
        evidence.planBinding.runSeed += 1
        try PairGraphEvidenceStore.save(
            evidence,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
        try setProjectArtifactMode(fixture.paths.pairGraphEvidenceURL)

        XCTAssertThrowsError(try ProjectArtifactValidator.validateFinishedProject(
            at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
            context: fixture.validationContext
        ))
    }

    func testGeometryPublicationRejectsRelabeledMatcherExecution() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var metadata = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        var geometry = try GeometryArtifactStore.load(
            from: fixture.paths.geometryManifestURL,
            projectPaths: fixture.paths
        )
        geometry.workerExecution.matchingInvocations[0]
            .pairExecution?.descriptorMatcher = .exact
        geometry.workerExecution.matchingInvocations[0]
            .pairExecution?.exactRecoveryReason = .faissCrash
        _ = try GeometryWorkerExecutionArtifactStore.save(
            geometry.workerExecution,
            to: GeometryWorkerExecutionArtifactStore.canonicalURL(for: fixture.paths),
            expectedBudget: fixture.plan.geometryWorkerBudget,
            projectPaths: fixture.paths
        )
        XCTAssertThrowsError(try GeometryArtifactStore.persist(
            geometry,
            metadata: &metadata,
            paths: fixture.paths
        )) { error in
            XCTAssertEqual(error as? GeometryArtifactStore.Error, .invalidWorkerExecution)
        }
    }

    func testValidateFinishedProjectRejectsLivePairDatabaseMutation() throws {
        let fixture = try makeFinishedProjectFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try setPrivateMode(fixture.paths.colmapDatabaseURL)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.paths.colmapDatabaseURL.path, &database), SQLITE_OK)
        let opened = try XCTUnwrap(database)
        XCTAssertEqual(
            sqlite3_exec(opened, "UPDATE matches SET rows = 0;", nil, nil, nil),
            SQLITE_OK
        )
        sqlite3_close(opened)
        try setProjectArtifactMode(fixture.paths.colmapDatabaseURL)

        XCTAssertThrowsError(try ProjectArtifactValidator.validateFinishedProject(
            at: fixture.paths.root,
            expectedInput: .photoFolder(fixture.input),
            context: fixture.validationContext
        ))
    }

    private struct FinishedProjectFixture {
        let root: URL
        let paths: ProjectPaths
        let input: URL
        let validationContext: FinishedProjectValidationContext
        let plan: ResolvedRunPlan
        let metadata: ProjectMetadata
        let geometry: GeometryArtifact
        let training: TrainingArtifact
        let output: URL
        let outputEvidence: ValidatedPlyArtifactEvidence
    }

    private struct FinishedCadenceOverride {
        let planned: IncrementalMappingCadenceArtifact
        let accepted: IncrementalMappingCadenceArtifact
        let trigger: MappingCadenceFallbackTrigger?
    }

    private enum RawFinishedProjectMutation: CaseIterable {
        case sourceReplacement
        case sourceTypeSpoof
        case sourceContentTypeSpoof
        case missingDevelopmentProvenance
        case controlledReplacement
        case sourceControlledDigestSwap
        case extraControlledFile
    }

    private func writeBoundsSamplingRegressionPly(
        at url: URL,
        reversed: Bool
    ) throws {
        let pointCount = 200_000
        var sampledRows = [Bool](repeating: false, count: pointCount)
        for slot in 0..<RobustSplatBounds.maximumFallbackSampleCount {
            let index = try XCTUnwrap(
                RobustSplatBounds.sampleIndex(slot: slot, pointCount: pointCount)
            )
            sampledRows[index] = true
        }
        XCTAssertEqual(sampledRows.count(where: { $0 }), pointCount / 2)

        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        let header = """
        ply
        format ascii 1.0
        element vertex \(pointCount)
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
        """
        try file.write(contentsOf: Data((header + "\n").utf8))
        var chunk = ""
        chunk.reserveCapacity(256 * 1_024)
        for row in 0..<pointCount {
            let sourceIndex = reversed ? pointCount - row - 1 : row
            let x = sampledRows[sourceIndex] ? "0" : "1000"
            chunk += "\(x) 0 0 1 1 1 -4 -4 -4 1 1 0 0 0\n"
            if chunk.utf8.count >= 256 * 1_024 {
                try file.write(contentsOf: Data(chunk.utf8))
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty {
            try file.write(contentsOf: Data(chunk.utf8))
        }
        try file.synchronize()
    }

    private func makeFinishedProjectFixture(
        canonicalPhotoOrder: Bool = true,
        includesRawSource: Bool = false,
        cadenceOverride: FinishedCadenceOverride? = nil
    ) throws -> FinishedProjectFixture {
        let root = try TestFileBuilder.makeTempDir()
        let project = root.appendingPathComponent("Finished.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: project)
        try paths.ensureDirectories()
        let input = root.appendingPathComponent("release-input", isDirectory: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let generatedPhotos = try (0..<3).map { index -> URL in
            let isRaw = includesRawSource && index == 0
            let source = input.appendingPathComponent(
                "generated-\(index).\(isRaw ? "dng" : "jpg")"
            )
            if isRaw {
                try TestFileBuilder.writeMinimalRawDNG(to: source)
                return source
            }
            XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
                url: source,
                size: 16,
                value: UInt8(192 + index * 8),
                utType: .jpeg
            ))
            return source
        }
        let sourcePhotos = try generatedPhotos.sorted {
            try GeometryArtifactStore.sha256(of: $0)
                > GeometryArtifactStore.sha256(of: $1)
        }.enumerated().map { index, generated -> URL in
            let source = input.appendingPathComponent(
                "source-\(index).\(generated.pathExtension.lowercased())"
            )
            try FileManager.default.moveItem(at: generated, to: source)
            return source
        }
        let requested = RequestedRunOptions(
            capturePath: .orbit,
            detailProfile: .fast,
            cameraGrouping: .sameCameraAndLens,
            lensProjection: .perspective,
            inputOrdering: .unordered,
            resourcePolicy: .automatic,
            photoSelection: .automatic
        )
        let inputSpec = InputSpec.photos(folder: input.path)
        let releaseHardware = HardwareProfile(
            memoryGB: 48,
            cpuCount: 16,
            gpuWorkingSetGB: 36
        )
        let validationContext = FinishedProjectValidationContext(
            hardwareProfile: releaseHardware
        )
        let plan = RunPlanResolver.resolve(
            requestedOptions: requested,
            input: inputSpec,
            hardware: releaseHardware,
            developmentOverrides: DevelopmentOverrides(benchmarkSeed: 42)
        )
        var metadata = ProjectMetadata(
            title: "Finished",
            input: inputSpec,
            requestedRunOptions: requested,
            resolvedRunPlan: plan
        )

        let importedPhotos = paths.originalsURL.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: importedPhotos, withIntermediateDirectories: true)
        let orderedSources = try sourcePhotos.sorted {
            try GeometryArtifactStore.sha256(of: $0)
                < GeometryArtifactStore.sha256(of: $1)
        }
        let importedSources = try orderedSources.enumerated().map { index, source -> URL in
            let isRaw = source.pathExtension.lowercased() == "dng"
            let destination = importedPhotos.appendingPathComponent(
                String(format: "photo-%04d.%@", index, isRaw ? "png" : "jpg")
            )
            if isRaw {
                XCTAssertTrue(try TestFileBuilder.writeGrayscaleImage(
                    url: destination,
                    size: 16,
                    value: 160,
                    utType: .png
                ))
            } else {
                try FileManager.default.copyItem(at: source, to: destination)
            }
            XCTAssertEqual(chmod(destination.path, 0o600), 0)
            return destination
        }
        metadata.input = .photos(folder: "Originals/Photos")
        let provisionalPhotoReceipts = try Array(
            zip(importedSources, orderedSources)
        ).enumerated().map { index, pair in
            let attributes = try FileManager.default.attributesOfItem(atPath: pair.0.path)
            let controlledSHA256 = try GeometryArtifactStore.sha256(of: pair.0)
            if pair.1.pathExtension.lowercased() == "dng" {
                let sourceAttributes = try FileManager.default.attributesOfItem(
                    atPath: pair.1.path
                )
                let sourceSHA256 = try GeometryArtifactStore.sha256(of: pair.1)
                return PhotoInputReceipt(
                    projectRelativePath: "Originals/Photos/\(pair.0.lastPathComponent)",
                    safeDisplayName: pair.1.lastPathComponent,
                    byteCount: try XCTUnwrap(attributes[.size] as? NSNumber).int64Value,
                    sha256: controlledSHA256,
                    pixelWidth: 16,
                    pixelHeight: 16,
                    orientation: 1,
                    typeIdentifier: UTType.png.identifier,
                    source: PhotoSourceProvenance(
                        byteCount: try XCTUnwrap(sourceAttributes[.size] as? NSNumber).int64Value,
                        sha256: sourceSHA256,
                        typeIdentifier: "com.adobe.raw-image"
                    ),
                    importMode: .rawDevelopment(RawDevelopmentEvidence(
                        decoderIdentifier: RawPhotoDecoder.decoderIdentifier,
                        decoderVersion: "fixture-1",
                        settings: .production(maximumPixelDimension: 4_096),
                        nativePixelWidth: 256,
                        nativePixelHeight: 256,
                        sourceOrientation: 1
                    )),
                    analysisEvidence: TestFileBuilder.photoAnalysisEvidence(
                        sourceSHA256: sourceSHA256,
                        seed: UInt8(truncatingIfNeeded: index)
                    ),
                    retainedRank: index
                )
            }
            return PhotoInputReceipt(
                projectRelativePath: "Originals/Photos/\(pair.0.lastPathComponent)",
                safeDisplayName: pair.1.lastPathComponent,
                byteCount: try XCTUnwrap(attributes[.size] as? NSNumber).int64Value,
                sha256: controlledSHA256,
                pixelWidth: 16,
                pixelHeight: 16,
                orientation: 1,
                typeIdentifier: "public.jpeg",
                analysisEvidence: TestFileBuilder.photoAnalysisEvidence(
                    sourceSHA256: controlledSHA256,
                    seed: UInt8(truncatingIfNeeded: index)
                ),
                retainedRank: index
            )
        }
        let rankedEvidence = try PhotoDiversitySelector.rank(
            provisionalPhotoReceipts.map(\.analysisEvidence),
            targetCount: provisionalPhotoReceipts.count
        )
        let retainedRankBySourceSHA256 = Dictionary(
            uniqueKeysWithValues: rankedEvidence.enumerated().map {
                ($0.element.sourceSHA256, $0.offset)
            }
        )
        let photoReceipts = try provisionalPhotoReceipts.map { receipt in
            try replacingPhotoReceipt(
                receipt,
                retainedRank: XCTUnwrap(
                    retainedRankBySourceSHA256[receipt.source.sha256]
                )
            )
        }
        metadata.photoInputReceipts = photoReceipts
        let photoSelectionArtifact = PhotoSelectionArtifact(
            strategy: .visualDiversity,
            analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
            analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256,
            selectorPolicyVersion: PhotoDiversitySelector.selectorPolicyVersion,
            selectorPolicySHA256: PhotoDiversitySelector.selectorPolicySHA256,
            inputOrdering: .unordered,
            requestedPhotoSelection: .automatic,
            admissionCapacity: photoReceipts.count,
            discoveredCount: photoReceipts.count,
            acceptedCount: photoReceipts.count,
            unreadableCount: 0,
            exactDuplicateCount: 0,
            companionDuplicateCount: 0,
            candidates: photoReceipts.enumerated().map { index, receipt in
                PhotoSelectionCandidateArtifact(
                    admissionOrdinal: index,
                    evidence: receipt.analysisEvidence,
                    retainedRank: receipt.retainedRank
                )
            },
            retainedSourceSHA256s: rankedEvidence.map(\.sourceSHA256),
            canonicalRetainedSourceSHA256s: photoReceipts.map(\.source.sha256)
        )
        let photoSelectionFile = try PhotoSelectionArtifactStore.save(
            photoSelectionArtifact,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths
        )
        metadata.photoSelectionReceipt = PhotoSelectionReceipt(
            projectRelativePath: PhotoSelectionReceipt.projectRelativePath,
            byteCount: photoSelectionFile.byteCount,
            sha256: photoSelectionFile.sha256,
            artifactSchemaVersion: photoSelectionArtifact.schemaVersion,
            analysisRecipeVersion: photoSelectionArtifact.analysisRecipeVersion,
            analysisRecipeSHA256: photoSelectionArtifact.analysisRecipeSHA256,
            selectorPolicyVersion: photoSelectionArtifact.selectorPolicyVersion,
            selectorPolicySHA256: photoSelectionArtifact.selectorPolicySHA256
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let selectedSources: [URL]
        if canonicalPhotoOrder {
            let importedBySourceSHA256 = Dictionary(
                uniqueKeysWithValues: zip(importedSources, photoReceipts).map {
                    ($0.1.source.sha256, $0.0)
                }
            )
            selectedSources = try rankedEvidence.map {
                try XCTUnwrap(importedBySourceSHA256[$0.sourceSHA256])
            }
        } else {
            selectedSources = Array(importedSources.reversed())
        }
        let imageNames = (0..<3).map { String(format: "frame_%06d.jpg", $0) }
        let selectedManifest = try zip(imageNames, selectedSources).map {
            name, source -> PipelineRunner.SelectedFrameMapping in
            let selected = paths.framesSelectedURL.appendingPathComponent(name)
            let exposure = try FrameScoring.scoreFrame(at: source).lowLightExposureEV
            let selectedExposure = exposure > 0 ? exposure : nil
            let normalization = PipelineRunner.SelectedFrameNormalization(
                sourcePixelWidth: 16,
                sourcePixelHeight: 16,
                sourceOrientation: 1,
                maximumPixelDimension: plan.maximumImageDimension,
                outputPixelWidth: 16,
                outputPixelHeight: 16,
                outputFormat: "jpg",
                transcoded: selectedExposure != nil
            )
            try PipelineRunner.reproduceSelectedFrame(
                source: source,
                destination: selected,
                normalization: normalization,
                exposureEV: selectedExposure
            )
            return PipelineRunner.SelectedFrameMapping(
                outputFileName: name,
                groupId: "photos",
                isVideo: false,
                lowLightExposureEV: selectedExposure,
                sourceProjectRelativePath: "Originals/Photos/\(source.lastPathComponent)",
                sourceSHA256: try GeometryArtifactStore.sha256(of: source),
                photoRetainedRank: try XCTUnwrap(
                    photoReceipts.first(where: {
                        $0.projectRelativePath
                            == "Originals/Photos/\(source.lastPathComponent)"
                    })?.retainedRank
                ),
                selectedSHA256: try GeometryArtifactStore.sha256(of: selected),
                selectedPixelSHA256: try PipelineRunner.selectedFramePixelSHA256(
                    at: selected
                ),
                normalization: normalization
            )
        }
        let selectedManifestData = try JSONEncoder().encode(selectedManifest)
        try selectedManifestData.write(
            to: paths.framesSelectedManifestURL,
            options: .atomic
        )
        let model = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        let conditioningPoints: [OrientationVector3] = (0..<25).map { index in
            let column = index % 5 - 2
            let row = index / 5 - 2
            return OrientationVector3(
                x: Double(column) * 0.75,
                y: Double(row) * 0.75,
                z: 12
            )
        }
        var pointTracks = Array(repeating: [String](), count: conditioningPoints.count)
        let images = imageNames.enumerated().flatMap { offset, name -> [String] in
            let imageID = offset + 1
            let centerX = (Double(offset) - Double(imageNames.count - 1) / 2) * 2
            let observations = conditioningPoints.enumerated().map { pointIndex, point in
                let x = 500 * (point.x - centerX) / point.z + 320
                let y = 500 * point.y / point.z + 240
                pointTracks[pointIndex].append("\(imageID) \(pointIndex)")
                return "\(x) \(y) \(pointIndex + 1)"
            }.joined(separator: " ")
            return [
                "\(imageID) 1 0 0 0 \(-centerX) 0 0 1 \(name)",
                observations,
            ]
        }.joined(separator: "\n") + "\n"
        let points = conditioningPoints.enumerated().map { index, point in
            "\(index + 1) \(point.x) \(point.y) \(point.z) 255 255 255 0 "
                + pointTracks[index].joined(separator: " ")
        }.joined(separator: "\n") + "\n"
        let modelContents = [
            "cameras.txt": "1 SIMPLE_RADIAL 640 480 500 320 240 0\n",
            "images.txt": images,
            "points3D.txt": points,
        ]
        var modelHashes: [String: String] = [:]
        for (name, contents) in modelContents {
            let data = Data(contents.utf8)
            let url = model.appendingPathComponent(name)
            try data.write(to: url, options: [.atomic])
            modelHashes[name] = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
        }
        let conditioningAnalysis = try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: model,
            maximumRayPairEvaluations:
                GeometryConditioningArtifact.defaultMaximumRayPairEvaluations
        )
        let orderedInput: Bool
        switch plan.pairingPolicy {
        case .unorderedRetrieval, .segmentedMixed:
            orderedInput = false
        case .orderedContinuous, .orderedOrbit, .orderedWalkthrough, .orderedLargeArea:
            orderedInput = true
        }
        let canonicalOrientation = CanonicalOrientationEstimator.estimate(
            cameras: conditioningAnalysis.residuals.cameraSamples,
            orderedImageNames: imageNames,
            orderedInput: orderedInput,
            allowCameraUpFallback: plan.pairingPolicy == .orderedContinuous
                || plan.pairingPolicy == .orderedWalkthrough,
            deterministicSeed: plan.runSeed
        ).artifact
        let modelClosureSHA256 = try XCTUnwrap(
            GeometryArtifactStore.modelClosureDigest(
                modelHashes,
                expectedNames: ["cameras.txt", "images.txt", "points3D.txt"]
            )
        )
        var workerExecution = makeGeometryWorkerExecutionArtifact(
            resolvedBudget: plan.geometryWorkerBudget
        )
        let pairPlan = try ColmapPairPlan.exhaustive(imageNames: imageNames)
        try makeFinishedPairDatabase(
            at: paths.colmapDatabaseURL,
            imageNames: imageNames,
            pairs: pairPlan.pairs
        )
        let selectedFramesDigest = try GeometryArtifactStore.selectedFramesDigest(
            orderedImageNames: imageNames,
            projectPaths: paths
        )
        let cameraGroupingReceipt = try ColmapCameraGroupingStore.normalize(
            databaseURL: paths.colmapDatabaseURL,
            selectedImages: imageNames.map {
                ColmapSelectedImageCameraEvidence(
                    imageName: $0,
                    sourceGroupID: "photos",
                    isVideo: false
                )
            },
            mode: .allSelectedImagesShared
        )
        let featureDatabaseDigest = try ColmapDatabaseDigester
            .digests(at: paths.colmapDatabaseURL).feature
        try ColmapFeatureEvidenceStore.save(
            ColmapFeatureEvidence(
                selectedFramesDigest: selectedFramesDigest,
                imageNames: imageNames,
                featureDatabaseDigest: featureDatabaseDigest,
                cameraGroupingReceipt: cameraGroupingReceipt,
                cameraInitializationReceipt: ColmapCameraInitializationReceipt(
                    recipe: .colmapAutomatic,
                    cameraModel: "SIMPLE_RADIAL",
                    singleCamera: true,
                    pixelWidth: nil,
                    pixelHeight: nil,
                    diagonalFieldOfViewDegrees: nil,
                    cameraParameters: nil,
                    priorFocalLength: false
                )
            ),
            to: paths.colmapFeatureEvidenceURL,
            projectPaths: paths
        )
        let pairInspection = try ColmapPairGraphInspector(
            databaseURL: paths.colmapDatabaseURL
        ).inspect(
            schedule: ColmapPairSchedule(
                imageNames: imageNames,
                pairs: pairPlan.pairs
            ),
            completion: .succeeded
        )
        let pairAttempt = PairGraphAttemptEvidence(
            artifact: PairMatchingAttemptArtifact(
                attemptNumber: 1,
                matcher: .faiss,
                recoveryLevel: .normal,
                outcome: .completed,
                scheduledPairCount: pairPlan.pairs.count,
                attemptedPairCount: pairInspection.attemptedPairCount,
                rawMatchedPairCount: pairInspection.rawMatchedPairCount,
                spatiallyVerifiedPairCount: pairInspection.spatiallyVerifiedPairCount,
                durationSeconds: 0.01
            ),
            scheduledPairs: pairPlan.pairs
        )
        let pairEvidence = PairGraphEvidence(
            selectedFramesDigest: selectedFramesDigest,
            imageNames: imageNames,
            pairingPolicy: plan.pairingPolicy,
            planBinding: PairGraphPlanBinding(plan),
            attempts: [pairAttempt],
            acceptedAttemptNumber: 1,
            acceptedInspection: pairInspection,
            retrievalWasScheduled: false,
            usedLocalVocabularyRetrieval: false,
            matchingDurationSeconds: 0.01,
            fallbackReasons: []
        )
        workerExecution.matchingInvocations[0].pairExecution =
            ColmapPairWorkerExecutionEvidence(
                attemptOrdinal: 1,
                descriptorMatcher: .faiss,
                scheduledPairCount: pairPlan.pairs.count,
                pairListDigest: pairPlan.sha256
            )
        let planCadence = IncrementalMappingCadenceArtifact(
            localMaxRefinements: plan.baLocalMaxRefinements,
            globalFramesRatio: plan.baGlobalFramesRatio,
            globalPointsRatio: plan.baGlobalPointsRatio,
            globalMaxRefinements: plan.baGlobalMaxRefinements,
            localMaxNumIterations: plan.baLocalMaxNumIterations,
            localFunctionTolerance: plan.baLocalFunctionTolerance,
            globalFunctionTolerance: plan.baGlobalFunctionTolerance,
            localImageCount: plan.baLocalImageCount
        )
        let plannedCadence = cadenceOverride?.planned ?? planCadence
        let acceptedCadence = cadenceOverride?.accepted ?? planCadence
        let cadenceTrigger = cadenceOverride?.trigger
        func mapperExecution(
            cadence: IncrementalMappingCadenceArtifact,
            evaluation: ColmapMapperEvaluationEvidence
        ) -> ColmapMapperWorkerExecutionEvidence {
            ColmapMapperWorkerExecutionEvidence(
                incrementalCadence: cadence,
                globalMaxNumIterations: 75,
                randomSeed: 42,
                refineFocalLength: true,
                minimumPairInlierCount: 15,
                pairGraphAttemptOrdinal: 1,
                pairListDigest: pairPlan.sha256,
                descriptorMatcher: .faiss,
                matchingDatabaseDigest: pairInspection.matchingDatabaseDigest,
                evaluation: evaluation
            )
        }
        let mapperIndex = try XCTUnwrap(
            workerExecution.mappingAndRefinementInvocations.firstIndex {
                $0.command == .mapper
            }
        )
        let analyzerIndex = try XCTUnwrap(
            workerExecution.mappingAndRefinementInvocations.firstIndex {
                $0.command == .modelAnalyzer
            }
        )
        var firstMapper = workerExecution.mappingAndRefinementInvocations[mapperIndex]
        var analyzer = workerExecution.mappingAndRefinementInvocations[analyzerIndex]
        if plannedCadence == acceptedCadence {
            firstMapper.mapperExecution = mapperExecution(
                cadence: acceptedCadence,
                evaluation: ColmapMapperEvaluationEvidence(
                    status: .accepted,
                    fallbackTrigger: nil
                )
            )
            workerExecution.mappingAndRefinementInvocations = [firstMapper, analyzer]
        } else {
            firstMapper.mapperExecution = mapperExecution(
                cadence: plannedCadence,
                evaluation: ColmapMapperEvaluationEvidence(
                    status: .rejected,
                    fallbackTrigger: cadenceTrigger
                )
            )
            var acceptedMapper = firstMapper
            acceptedMapper.mappingAttemptOrdinal = 2
            acceptedMapper.mapperExecution = mapperExecution(
                cadence: acceptedCadence,
                evaluation: ColmapMapperEvaluationEvidence(
                    status: .accepted,
                    fallbackTrigger: nil
                )
            )
            analyzer.mappingAttemptOrdinal = 2
            workerExecution.mappingAndRefinementInvocations = [
                firstMapper,
                acceptedMapper,
                analyzer,
            ]
        }
        _ = try GeometryWorkerExecutionArtifactStore.save(
            workerExecution,
            to: GeometryWorkerExecutionArtifactStore.canonicalURL(for: paths),
            expectedBudget: plan.geometryWorkerBudget,
            projectPaths: paths
        )
        try PairGraphEvidenceStore.save(
            pairEvidence,
            to: paths.pairGraphEvidenceURL,
            projectPaths: paths
        )
        let geometry = GeometryArtifact(
            schemaVersion: GeometryArtifact.currentSchemaVersion,
            solverVersion: "colmap; COLMAP 4.1.1 (git a0d785f)",
            runtimeVersion: "toolchain 2.0.0",
            modelVersion: "none",
            inputDigest: try GeometryArtifactStore.inputDigest(projectPaths: paths),
            selectedFramesDigest: selectedFramesDigest,
            orderedImageNames: imageNames,
            orderedImageTimestamps: Array(repeating: nil, count: imageNames.count),
            sourceModelPath: "SfM/colmap/sparse/0",
            poseConvention: "world-to-camera",
            quaternionOrder: "wxyz",
            handedness: "right-handed",
            scaleType: "arbitrary-sim3",
            cameraModel: conditioningAnalysis.residuals.cameraModel,
            cameraGrouping: plan.cameraGrouping,
            cameraGroupingReceipt: cameraGroupingReceipt,
            cameraInitializationReceipt: ColmapCameraInitializationReceipt(
                recipe: .colmapAutomatic,
                cameraModel: conditioningAnalysis.residuals.cameraModel,
                singleCamera: true,
                pixelWidth: nil,
                pixelHeight: nil,
                diagonalFieldOfViewDegrees: nil,
                cameraParameters: nil,
                priorFocalLength: false
            ),
            featureDatabaseDigest: featureDatabaseDigest,
            registeredViewCount: imageNames.count,
            totalViewCount: imageNames.count,
            observationCount: conditioningAnalysis.residuals.observationCount,
            pointCount: conditioningAnalysis.residuals.pointCount,
            residualProvenance: "colmap-text-tracks-v1",
            medianPixelResidual: conditioningAnalysis.residuals.medianPixelResidual,
            p90PixelResidual: conditioningAnalysis.residuals.p90PixelResidual,
            conditioning: GeometryConditioningArtifact(
                sourceModelClosureSHA256: modelClosureSHA256,
                measurement: conditioningAnalysis.measurement
            ),
            timings: [
                "sfmMapping": 0.1,
                "orientation_estimation_seconds": 0.001,
            ],
            peakMemoryBytes: 1_024,
            modelHashes: modelHashes,
            provenance: GeometryProvenance(
                toolchainVersion: "2.0.0",
                solver: GeometryComponentProvenance(
                    identifier: "colmap",
                    version: "4.1.1",
                    revision: "a0d785fba74b2664f31edc4a29026a8b27c00f67",
                    payloadSHA256: workerExecution.colmapRuntimeClosure.closureSHA256
                ),
                runtime: nil,
                model: nil
            ),
            workerExecution: workerExecution,
            pairGraph: try pairEvidence.pairGraphArtifact(),
            mapping: MappingArtifact(
                modelCount: 1,
                largestModelRegisteredViewCount: imageNames.count,
                secondLargestModelRegisteredViewCount: 0,
                unionRegisteredViewCount: imageNames.count,
                attemptCount: plannedCadence == acceptedCadence ? 1 : 2,
                acceptedMappingAttemptOrdinal: plannedCadence == acceptedCadence ? 1 : 2,
                acceptedRefinementKind: .incrementalGlobal,
                acceptedRefinementInvocationCount: 1,
                plannedIncrementalCadence: plannedCadence,
                incrementalCadence: acceptedCadence,
                cadenceFallbackTrigger: cadenceTrigger,
                canonicalModelPublication: CanonicalModelPublicationArtifact(
                    kind: .directText,
                    sourceModelHashes: modelHashes,
                    conversion: nil
                ),
                fallbackReason: plannedCadence == acceptedCadence
                    ? nil
                    : "Mapper quality gate retried with a denser cadence."
            ),
            canonicalOrientation: canonicalOrientation
        )
        try GeometryArtifactStore.persist(geometry, metadata: &metadata, paths: paths)

        let dataset = paths.trainingURL.appendingPathComponent(
            "msplat_dataset",
            isDirectory: true
        )
        let datasetImages = dataset.appendingPathComponent("images", isDirectory: true)
        let datasetSparse = dataset.appendingPathComponent("sparse/0", isDirectory: true)
        try FileManager.default.createDirectory(
            at: datasetImages,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: datasetSparse,
            withIntermediateDirectories: true
        )
        for name in imageNames {
            try FileManager.default.copyItem(
                at: paths.framesSelectedURL.appendingPathComponent(name),
                to: datasetImages.appendingPathComponent(name)
            )
        }
        for name in ["cameras.bin", "points3D.bin"] {
            try Data("binary \(name)".utf8).write(
                to: datasetSparse.appendingPathComponent(name),
                options: .atomic
            )
        }
        try makeColmapImagesBinary(imageNames).write(
            to: datasetSparse.appendingPathComponent("images.bin"),
            options: .atomic
        )
        try MsplatOrientationOverlay.write(
            geometry.canonicalOrientation,
            to: datasetSparse
        )
        let datasetIdentity = try MsplatDatasetIdentity.compute(
            imageDirectory: datasetImages,
            sparseDirectory: datasetSparse
        )

        let output = paths.outputURL.appendingPathComponent("splat.ply")
        try TestFileBuilder.writeMinimalPly(at: output, vertexCount: 2)
        try setPrivateMode(output)
        let outputEvidence = try ProjectArtifactValidator.validatedPlyEvidence(at: output)
        let outputSceneBounds = try XCTUnwrap(
            SplatSceneBoundsCalculator.compute(at: output)
        )
        let training = TrainingArtifact(
            trainerVersion: "1.1.3 (git 106499b)",
            runtimeVersion: "native-metal-cli-v2",
            trainerBuildDigest: String(repeating: "1", count: 64),
            inputDigest: datasetIdentity.inputDigest,
            geometryDigest: datasetIdentity.geometryDigest,
            datasetDerivation: MsplatDatasetDerivationArtifact(
                sourceGeometryManifestSHA256: try GeometryArtifactStore.manifestDigest(
                    matching: geometry,
                    at: paths.geometryManifestURL
                ),
                sourceSelectedFramesDigest: geometry.selectedFramesDigest,
                preparationKind: .direct,
                maximumImageDimension: plan.maximumImageDimension,
                toolchainVersion: geometry.provenance.toolchainVersion,
                colmapProvenance: geometry.provenance.solver,
                registeredImageNames: imageNames,
                datasetInputDigest: datasetIdentity.inputDigest,
                datasetGeometryDigest: datasetIdentity.geometryDigest
            ),
            detailProfile: requested.detailProfile,
            iterationLimit: plan.trainerIterationLimit,
            plateauWindow: plan.plateauWindow,
            cameraOrderSeed: plan.runSeed,
            completedIteration: plan.trainerIterationLimit,
            checkpointPath: nil,
            checkpointDigest: nil,
            outputPath: "Output/splat.ply",
            outputSHA256: outputEvidence.sha256,
            outputBytes: Int64(outputEvidence.byteCount),
            gaussianCount: outputEvidence.vertexCount,
            elapsedSeconds: 1,
            peakMemoryBytes: 1_024,
            memoryBudgetBytes: plan.trainerMemoryBudgetBytes,
            resourceAdmission: makeTestTrainingResourceAdmission(),
            rasterFallbackCount: 0,
            rasterExactFallbackElapsedSeconds: 0,
            rasterExactBufferGrowthCount: 0,
            rasterExactBufferBytesAdded: 0,
            rasterReplayElapsedSeconds: 0,
            rasterPeakExactIntersectionCapacity: 0,
            droppedIntersectionCount: 0,
            sceneBounds: outputSceneBounds,
            completionStatus: .completed
        )
        try TrainingArtifactStore.persist(training, paths: paths)
        metadata.state = PipelineState(stage: .done, lastError: nil)
        metadata.checkpoint = nil
        metadata.lastRunStartedAt = nil
        metadata.stageTimings = [
            StageTimingRecord(
                stage: .importInput,
                startedAt: Date(timeIntervalSince1970: 1_000),
                durationSeconds: 1
            ),
            StageTimingRecord(
                stage: .selectFrames,
                startedAt: Date(timeIntervalSince1970: 1_001),
                durationSeconds: 2
            ),
            StageTimingRecord(
                stage: .sfmFeatures,
                startedAt: Date(timeIntervalSince1970: 1_003),
                durationSeconds: 3
            ),
            StageTimingRecord(
                stage: .sfmMatching,
                startedAt: Date(timeIntervalSince1970: 1_006),
                durationSeconds: 4
            ),
            StageTimingRecord(
                stage: .sfmMapping,
                startedAt: Date(timeIntervalSince1970: 1_010),
                durationSeconds: 5
            ),
            StageTimingRecord(
                stage: .trainSplat,
                startedAt: Date(timeIntervalSince1970: 1_015),
                durationSeconds: 6
            ),
            StageTimingRecord(
                stage: .exportSplat,
                startedAt: Date(timeIntervalSince1970: 1_021),
                durationSeconds: 7
            ),
        ]
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let protectedFixtureFiles = [
            paths.metadataURL,
            paths.photoSelectionArtifactURL,
            paths.geometryManifestURL,
            paths.trainingManifestURL,
            paths.framesSelectedManifestURL,
            GeometryWorkerExecutionArtifactStore.canonicalURL(for: paths),
            paths.colmapFeatureEvidenceURL,
            paths.pairGraphEvidenceURL,
            paths.colmapDatabaseURL,
            model.appendingPathComponent("cameras.txt"),
            model.appendingPathComponent("images.txt"),
            model.appendingPathComponent("points3D.txt"),
            output,
        ] + imageNames.map { name in paths.framesSelectedURL.appendingPathComponent(name) }
            + imageNames.map { name in datasetImages.appendingPathComponent(name) }
            + [
                "cameras.bin",
                "images.bin",
                "points3D.bin",
                MsplatOrientationOverlay.fileName,
            ].map { name in datasetSparse.appendingPathComponent(name) }
        for url in protectedFixtureFiles {
            try setProjectArtifactMode(url)
        }
        try setPrivateMode(paths.photoSelectionArtifactURL)
        return FinishedProjectFixture(
            root: root,
            paths: paths,
            input: input,
            validationContext: validationContext,
            plan: plan,
            metadata: metadata,
            geometry: geometry,
            training: training,
            output: output,
            outputEvidence: outputEvidence
        )
    }

    private func makeFinishedPairDatabase(
        at url: URL,
        imageNames: [String],
        pairs: [ColmapScheduledPair]
    ) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "ProjectArtifactValidatorTests", code: 1)
        }
        defer { sqlite3_close(database) }
        var cameraParameters = Data()
        for value in [500.0, 320.0, 240.0, 0.0] {
            appendLittleEndian(value.bitPattern, to: &cameraParameters)
        }
        let cameraParameterHex = cameraParameters.map {
            String(format: "%02x", $0)
        }.joined()
        try executeFinishedPairSQL(
            """
            CREATE TABLE cameras(
                camera_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                model INTEGER NOT NULL,
                width INTEGER NOT NULL,
                height INTEGER NOT NULL,
                params BLOB,
                prior_focal_length INTEGER NOT NULL
            );
            CREATE TABLE images(
                image_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                name TEXT NOT NULL UNIQUE,
                camera_id INTEGER NOT NULL,
                CONSTRAINT image_id_check CHECK(
                    image_id >= 0 AND image_id < 2147483647
                ),
                FOREIGN KEY(camera_id) REFERENCES cameras(camera_id)
            );
            CREATE UNIQUE INDEX index_name ON images(name);
            CREATE TABLE rigs(
                rig_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                ref_sensor_id INTEGER NOT NULL,
                ref_sensor_type INTEGER NOT NULL
            );
            CREATE UNIQUE INDEX rig_ref_sensor_assignment
                ON rigs(ref_sensor_id, ref_sensor_type);
            CREATE TABLE rig_sensors(
                rig_id INTEGER NOT NULL,
                sensor_id INTEGER NOT NULL,
                sensor_type INTEGER NOT NULL,
                sensor_from_rig BLOB,
                FOREIGN KEY(rig_id) REFERENCES rigs(rig_id) ON DELETE CASCADE
            );
            CREATE UNIQUE INDEX rig_sensor_assignment
                ON rig_sensors(sensor_id, sensor_type);
            CREATE TABLE frames(
                frame_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                rig_id INTEGER NOT NULL,
                FOREIGN KEY(rig_id) REFERENCES rigs(rig_id) ON DELETE CASCADE
            );
            CREATE TABLE frame_data(
                frame_id INTEGER NOT NULL,
                data_id INTEGER NOT NULL,
                sensor_id INTEGER NOT NULL,
                sensor_type INTEGER NOT NULL,
                FOREIGN KEY(frame_id) REFERENCES frames(frame_id) ON DELETE CASCADE
            );
            CREATE UNIQUE INDEX frame_sensor_assignment
                ON frame_data(data_id, sensor_type);
            CREATE TABLE pose_priors(
                pose_prior_id INTEGER PRIMARY KEY NOT NULL,
                corr_data_id INTEGER NOT NULL,
                corr_sensor_id INTEGER NOT NULL,
                corr_sensor_type INTEGER NOT NULL,
                position BLOB,
                position_covariance BLOB,
                gravity BLOB,
                coordinate_system INTEGER NOT NULL
            );
            CREATE UNIQUE INDEX pose_prior_data_assignment
                ON pose_priors(corr_data_id, corr_sensor_id, corr_sensor_type);
            CREATE TABLE keypoints(
                image_id INTEGER PRIMARY KEY NOT NULL,
                rows INTEGER NOT NULL,
                cols INTEGER NOT NULL,
                data BLOB,
                FOREIGN KEY(image_id) REFERENCES images(image_id) ON DELETE CASCADE
            );
            CREATE TABLE descriptors(
                image_id INTEGER PRIMARY KEY NOT NULL,
                type INTEGER NOT NULL,
                rows INTEGER NOT NULL,
                cols INTEGER NOT NULL,
                data BLOB,
                FOREIGN KEY(image_id) REFERENCES images(image_id) ON DELETE CASCADE
            );
            CREATE TABLE matches(
                pair_id INTEGER PRIMARY KEY NOT NULL,
                rows INTEGER NOT NULL,
                cols INTEGER NOT NULL,
                data BLOB
            );
            CREATE TABLE two_view_geometries(
                pair_id INTEGER PRIMARY KEY NOT NULL,
                rows INTEGER NOT NULL,
                cols INTEGER NOT NULL,
                data BLOB,
                config INTEGER NOT NULL,
                F BLOB,
                E BLOB,
                H BLOB,
                qvec BLOB,
                tvec BLOB
            );
            INSERT INTO cameras(
                camera_id, model, width, height, params, prior_focal_length
            ) VALUES (1, 2, 640, 480, X'\(cameraParameterHex)', 0);
            INSERT INTO rigs(rig_id, ref_sensor_id, ref_sensor_type)
            VALUES (1, 1, 0);
            """,
            database: database
        )
        let orderedImageNames = imageNames.sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }
        for (index, name) in orderedImageNames.enumerated() {
            let imageID = index + 1
            try executeFinishedPairSQL(
                """
                INSERT INTO images(image_id, name, camera_id)
                VALUES (\(imageID), '\(name)', 1);
                INSERT INTO frames(frame_id, rig_id)
                VALUES (\(imageID), 1);
                INSERT INTO frame_data(
                    frame_id, data_id, sensor_id, sensor_type
                ) VALUES (\(imageID), \(imageID), 1, 0);
                INSERT INTO keypoints(image_id, rows, cols, data)
                VALUES (\(imageID), 1, 4, X'00000000000000000000000000000000');
                INSERT INTO descriptors(image_id, type, rows, cols, data)
                VALUES (\(imageID), 0, 1, 128, zeroblob(128));
                """,
                database: database
            )
        }
        let indexByName = Dictionary(
            uniqueKeysWithValues: orderedImageNames.enumerated().map {
                ($0.element, $0.offset + 1)
            }
        )
        for pair in pairs {
            let first = try XCTUnwrap(indexByName[pair.firstImageName])
            let second = try XCTUnwrap(indexByName[pair.secondImageName])
            let pairID = Int64(min(first, second)) * 2_147_483_647
                + Int64(max(first, second))
            try executeFinishedPairSQL(
                """
                INSERT INTO matches(pair_id, rows, cols, data)
                VALUES (\(pairID), 15, 2, X'0000000000000000');
                INSERT INTO two_view_geometries(pair_id, rows, cols, data, config)
                VALUES (\(pairID), 15, 2, X'0000000000000000', 2);
                """,
                database: database
            )
        }
    }

    private func executeFinishedPairSQL(
        _ sql: String,
        database: OpaquePointer
    ) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "SQLite error"
            throw NSError(
                domain: "ProjectArtifactValidatorTests",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private func makeColmapImagesBinary(_ imageNames: [String]) -> Data {
        var data = Data()
        appendLittleEndian(UInt64(imageNames.count), to: &data)
        for (offset, name) in imageNames.enumerated() {
            appendLittleEndian(UInt32(offset + 1), to: &data)
            for value in [1.0, 0, 0, 0, 0, 0, 0] {
                appendLittleEndian(value.bitPattern, to: &data)
            }
            appendLittleEndian(UInt32(1), to: &data)
            data.append(contentsOf: name.utf8)
            data.append(0)
            appendLittleEndian(UInt64(0), to: &data)
        }
        return data
    }

    private func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func makeToolchainEvidence(
        toolchainVersion: String,
        colmapSHA256: String,
        trainerBuildDigest: String,
        openMPSHA256: String = String(repeating: "b", count: 64),
        colmapSourceVersion: String = "4.1.1",
        duplicateColmapProvenance: Bool = false,
        omitOpenMPFromCriticalFiles: Bool = false,
        omitOpenMPFromDeclaredContents: Bool = false
    ) -> ToolchainInstallationEvidence {
        let colmapRecord = ToolchainInstallationEvidence.ProvenanceRecord(
            path: "provenance/colmap.json",
            fileSHA256: String(repeating: "d", count: 64),
            canonicalJSONSHA256: String(repeating: "1", count: 64),
            stringFields: [
                "toolchain_name": "colmap",
                "source_version": colmapSourceVersion,
                "source_commit": "a0d785fba74b2664f31edc4a29026a8b27c00f67",
                "executable_sha256": colmapSHA256,
            ]
        )
        var criticalFiles = [
            "bin/colmap": colmapSHA256,
            "bin/easysplat-train": String(repeating: "b", count: 64),
            "bin/default.metallib": String(repeating: "c", count: 64),
            "provenance/colmap.json": String(repeating: "d", count: 64),
            "msplat/build_info.json": String(repeating: "e", count: 64),
        ]
        if !omitOpenMPFromCriticalFiles {
            criticalFiles["lib/libomp.dylib"] = openMPSHA256
        }
        var declaredContents = [
            "bin/colmap",
            "bin/easysplat-train",
            "bin/default.metallib",
            "provenance/colmap.json",
            "msplat/build_info.json",
        ]
        if !omitOpenMPFromDeclaredContents {
            declaredContents.append("lib/libomp.dylib")
        }
        return ToolchainInstallationEvidence(
            toolchainVersion: toolchainVersion,
            keyID: String(repeating: "5", count: 64),
            canonicalManifestSHA256: String(repeating: "6", count: 64),
            signatureSHA256: String(repeating: "7", count: 64),
            closureSHA256: String(repeating: "8", count: 64),
            installationIdentitySHA256: String(repeating: "9", count: 64),
            installedArtifacts: ["macos-arm64-core": String(repeating: "a", count: 64)],
            installedCapabilities: [
                ToolchainCapability.core.rawValue,
                ToolchainCapability.colmap.rawValue,
                ToolchainCapability.msplat.rawValue,
            ],
            installedCriticalFileSHA256: criticalFiles,
            nativeTrainerBuildDigest: trainerBuildDigest,
            signedComponents: [
                ToolchainInstallationEvidence.SignedComponent(
                    name: "macos-arm64-core",
                    archiveSHA256: String(repeating: "a", count: 64),
                    expandedClosureSHA256: String(repeating: "f", count: 64),
                    capabilities: [
                        ToolchainCapability.core.rawValue,
                        ToolchainCapability.colmap.rawValue,
                        ToolchainCapability.msplat.rawValue,
                    ],
                    declaredContents: declaredContents
                ),
            ],
            provenanceRecords: [
                colmapRecord,
                ToolchainInstallationEvidence.ProvenanceRecord(
                    path: "msplat/build_info.json",
                    fileSHA256: String(repeating: "e", count: 64),
                    canonicalJSONSHA256: String(repeating: "2", count: 64),
                    stringFields: [
                        "toolchain_name": "msplat",
                        "source_version": "1.1.3",
                        "source_commit": "106499b0a53f82b0c92d013b0861fbebd341b17e",
                        "executable_sha256": String(repeating: "b", count: 64),
                        "metallib_sha256": String(repeating: "c", count: 64),
                    ]
                ),
            ] + (duplicateColmapProvenance ? [colmapRecord] : [])
        )
    }

    private func setPrivateMode(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func writeCameraMetadataJPEG(
        at url: URL,
        focalLength35mm: Int,
        width: Int = 16,
        height: Int = 12
    ) throws {
        var pixels = [UInt8](repeating: 128, count: width * height)
        let image = try pixels.withUnsafeMutableBytes { bytes in
            try XCTUnwrap(CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData)),
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ))
        }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(
            destination,
            image,
            [
                kCGImagePropertyTIFFDictionary: [
                    kCGImagePropertyTIFFMake: "Fixture Camera Maker",
                    kCGImagePropertyTIFFModel: "Fixture Camera Model",
                ],
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifFocalLength: 6.3,
                    kCGImagePropertyExifFocalLenIn35mmFilm: focalLength35mm,
                ],
                kCGImageDestinationLossyCompressionQuality: 1.0,
            ] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func makeCameraMeasurement(
        imageNames: [String],
        cameraIDsByImageName: [String: Int]
    ) -> ColmapResidualAnalyzer.Result {
        let cameraIDs = Set(cameraIDsByImageName.values)
        return ColmapResidualAnalyzer.Result(
            registeredViewCount: imageNames.count,
            registeredImageNames: imageNames,
            measuredImageNames: imageNames,
            observationCountByImage: Dictionary(
                uniqueKeysWithValues: imageNames.map { ($0, 1) }
            ),
            cameraModel: "SIMPLE_RADIAL",
            cameraModelsByID: Dictionary(
                uniqueKeysWithValues: cameraIDs.map { ($0, "SIMPLE_RADIAL") }
            ),
            cameraIDsByImageName: cameraIDsByImageName,
            cameraSamples: [],
            pointCount: 1,
            observationCount: imageNames.count,
            pointTrackTopologySHA256: String(repeating: "0", count: 64),
            meanPixelResidual: 0,
            medianPixelResidual: 0,
            p90PixelResidual: 0,
            provenance: "track_reprojection_pixels_v1"
        )
    }

    private func rawReceipt(
        from receipt: PhotoInputReceipt,
        source: PhotoSourceProvenance,
        importMode: PhotoImportMode
    ) -> PhotoInputReceipt {
        PhotoInputReceipt(
            projectRelativePath: receipt.projectRelativePath,
            safeDisplayName: receipt.safeDisplayName,
            byteCount: receipt.byteCount,
            sha256: receipt.sha256,
            pixelWidth: receipt.pixelWidth,
            pixelHeight: receipt.pixelHeight,
            orientation: receipt.orientation,
            typeIdentifier: receipt.typeIdentifier,
            source: source,
            importMode: importMode,
            analysisEvidence: TestFileBuilder.photoAnalysisEvidence(
                sourceSHA256: source.sha256
            ),
            retainedRank: receipt.retainedRank
        )
    }

    private func replacingPhotoReceipt(
        _ receipt: PhotoInputReceipt,
        retainedRank: Int
    ) -> PhotoInputReceipt {
        PhotoInputReceipt(
            projectRelativePath: receipt.projectRelativePath,
            safeDisplayName: receipt.safeDisplayName,
            byteCount: receipt.byteCount,
            sha256: receipt.sha256,
            pixelWidth: receipt.pixelWidth,
            pixelHeight: receipt.pixelHeight,
            orientation: receipt.orientation,
            typeIdentifier: receipt.typeIdentifier,
            source: receipt.source,
            importMode: receipt.importMode,
            analysisEvidence: receipt.analysisEvidence,
            retainedRank: retainedRank
        )
    }

    private func authenticatedPhotoProjection(
        in fixture: FinishedProjectFixture,
        inputOrdering: InputOrdering,
        photoSelection: PhotoSelection
    ) throws -> PhotoSelectionProjection {
        var metadata = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        var requested = metadata.requestedRunOptions
        requested.inputOrdering = inputOrdering
        requested.photoSelection = photoSelection
        let plan = RunPlanResolver.resolve(
            requestedOptions: requested,
            input: metadata.input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: DevelopmentOverrides(benchmarkSeed: 42)
        )
        let receipts = try XCTUnwrap(metadata.photoInputReceipts)
        let canonicalSourceSHA256s = receipts.map(\.source.sha256)
        let strategy: PhotoSelectionStrategy
        let retainedSourceSHA256s: [String]
        switch (photoSelection, inputOrdering) {
        case (.automatic, .continuous):
            strategy = .continuousEvenSpacing
            retainedSourceSHA256s = canonicalSourceSHA256s
        case (.automatic, .unordered):
            strategy = .visualDiversity
            retainedSourceSHA256s = try PhotoDiversitySelector.rank(
                receipts.map(\.analysisEvidence),
                targetCount: receipts.count
            ).map(\.sourceSHA256)
        case (.useAllValidPhotos, .continuous):
            strategy = .useAll
            retainedSourceSHA256s = canonicalSourceSHA256s
        case (.useAllValidPhotos, .unordered):
            strategy = .useAll
            retainedSourceSHA256s = canonicalSourceSHA256s.sorted()
            XCTAssertEqual(canonicalSourceSHA256s, retainedSourceSHA256s)
        default:
            throw XCTSkip("The authenticated projection fixture requires resolved ordering.")
        }
        let retainedRankBySHA256 = Dictionary(
            uniqueKeysWithValues: retainedSourceSHA256s.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        let boundReceipts = try receipts.map { receipt in
            try replacingPhotoReceipt(
                receipt,
                retainedRank: XCTUnwrap(retainedRankBySHA256[receipt.source.sha256])
            )
        }
        let artifact = PhotoSelectionArtifact(
            strategy: strategy,
            analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
            analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256,
            selectorPolicyVersion: PhotoDiversitySelector.selectorPolicyVersion,
            selectorPolicySHA256: PhotoDiversitySelector.selectorPolicySHA256,
            inputOrdering: plan.inputOrdering,
            requestedPhotoSelection: plan.photoSelection,
            admissionCapacity: boundReceipts.count,
            discoveredCount: boundReceipts.count,
            acceptedCount: boundReceipts.count,
            unreadableCount: 0,
            exactDuplicateCount: 0,
            companionDuplicateCount: 0,
            candidates: boundReceipts.enumerated().map { index, receipt in
                PhotoSelectionCandidateArtifact(
                    admissionOrdinal: index,
                    evidence: receipt.analysisEvidence,
                    retainedRank: receipt.retainedRank
                )
            },
            retainedSourceSHA256s: retainedSourceSHA256s,
            canonicalRetainedSourceSHA256s: canonicalSourceSHA256s
        )
        let evidence = try PhotoSelectionArtifactStore.save(
            artifact,
            to: fixture.paths.photoSelectionArtifactURL,
            projectPaths: fixture.paths
        )
        metadata.requestedRunOptions = requested
        metadata.resolvedRunPlan = plan
        metadata.photoInputReceipts = boundReceipts
        metadata.photoSelectionReceipt = PhotoSelectionReceipt(
            projectRelativePath: PhotoSelectionReceipt.projectRelativePath,
            byteCount: evidence.byteCount,
            sha256: evidence.sha256,
            artifactSchemaVersion: artifact.schemaVersion,
            analysisRecipeVersion: artifact.analysisRecipeVersion,
            analysisRecipeSHA256: artifact.analysisRecipeSHA256,
            selectorPolicyVersion: artifact.selectorPolicyVersion,
            selectorPolicySHA256: artifact.selectorPolicySHA256
        )
        return try XCTUnwrap(PhotoSelectionProjection.loadVerified(
            metadata: metadata,
            paths: fixture.paths
        ))
    }

    private func writeUncheckedProjectMetadata(
        _ metadata: ProjectMetadata,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: url, options: .atomic)
    }

    private func setProjectArtifactMode(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: url.path
        )
    }

    private func writeBinarySplat(
        at url: URL,
        format: String,
        firstFloatBits: UInt32
    ) throws {
        let properties = [
            "x", "y", "z", "f_dc_0", "f_dc_1", "f_dc_2",
            "scale_0", "scale_1", "scale_2", "opacity",
            "rot_0", "rot_1", "rot_2", "rot_3",
        ]
        var data = Data(
            ([
                "ply",
                "format \(format) 1.0",
                "element vertex 1",
            ] + properties.map { "property float \($0)" } + ["end_header", ""])
                .joined(separator: "\n")
                .utf8
        )
        let littleEndian = format == "binary_little_endian"
        for index in properties.indices {
            let bits = index == 0 ? firstFloatBits : UInt32(0)
            let byteOrder = littleEndian ? Array(0..<4) : Array((0..<4).reversed())
            for byteIndex in byteOrder {
                data.append(UInt8(truncatingIfNeeded: bits >> UInt32(byteIndex * 8)))
            }
        }
        try data.write(to: url)
    }

    private func mutateFirstVertexCoordinate(at url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { Darwin.close(descriptor) }
        let bytes = try Data(contentsOf: url)
        guard let bodyMarker = bytes.range(of: Data("end_header\n0 ".utf8)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let offset = off_t(bodyMarker.upperBound - 2)
        var replacement = UInt8(ascii: "1")
        guard Darwin.pwrite(descriptor, &replacement, 1, offset) == 1,
              Darwin.fsync(descriptor) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private final class PlyPublicationCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}
