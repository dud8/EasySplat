import Darwin
import XCTest
@testable import EasySplatCore

@MainActor
final class ToolchainManagerTests: XCTestCase {
    func testValidateToolchainSucceeds() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root, brushHasShebang: true, includeBrushReal: true)

        let runner = makeValidationRunner(root: root, brushArchPath: "bin/brush.real")

        let manager = ToolchainManager(runner: runner)
        let toolchain = try manager.test_validateToolchain(root: root)
        XCTAssertEqual(toolchain.root, root)
    }

    func testValidateToolchainAcceptsNativeMsplatClosure() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let msplat = root.appendingPathComponent("bin/easysplat-train")

        let runner = makeValidationRunner(root: root)

        let manager = ToolchainManager(runner: runner)
        let toolchain = try manager.test_validateToolchain(root: root)
        XCTAssertEqual(toolchain.msplat, msplat)
    }

    func testValidateToolchainAcceptsBrushOnlyToolchainWhenMsplatMissing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root, includeMsplat: false)

        let runner = makeValidationRunner(root: root)

        let manager = ToolchainManager(runner: runner)
        let toolchain = try manager.test_validateToolchain(root: root)
        XCTAssertEqual(toolchain.msplat, root.appendingPathComponent("bin/easysplat-train"))
    }

    func testValidateToolchainNormalizesPackagedMsplatExecutableBit() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let msplat = root.appendingPathComponent("bin/easysplat-train")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: msplat.path)

        let runner = makeValidationRunner(root: root)

        let manager = ToolchainManager(runner: runner)
        let toolchain = try manager.test_validateToolchain(root: root)
        XCTAssertEqual(toolchain.msplat, msplat)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: msplat.path))
    }

    func testValidateToolchainRejectsBrokenPackagedMsplat() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let runner = makeValidationRunner(root: root, msplatSelfCheckExitCode: 2)

        let manager = ToolchainManager(runner: runner)
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("easysplat-train self-check failed"), "expected msplat launch failure; got \(message)")
        }
    }

    func testValidateToolchainFailsWhenPackagedMsplatRequiredFilesAreMissing() throws {
        let cases: [(String, String)] = [
            ("bin/easysplat-train", "bin/easysplat-train"),
            ("bin/default.metallib", "bin/default.metallib"),
            ("msplat/build_info.json", "msplat/build_info.json"),
            ("msplat/LICENSE", "msplat/LICENSE")
        ]

        for (relativePath, expectedName) in cases {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try ToolchainFixtureBuilder.createToolchain(at: root)
            try FileManager.default.removeItem(at: root.appendingPathComponent(relativePath))

            let manager = ToolchainManager(runner: makeValidationRunner(root: root))
            XCTAssertThrowsError(try manager.test_validateToolchain(root: root), "Expected missing error for \(relativePath)") { error in
                switch error {
                case ToolchainManager.ToolchainError.missingBinary(let name),
                     ToolchainManager.ToolchainError.missingLibrary(let name):
                    XCTAssertEqual(name, expectedName)
                default:
                    XCTFail("Expected missing file error for \(relativePath), got \(error)")
                }
            }
        }
    }

    func testValidateToolchainRejectsInvalidPackagedMsplatMetadata() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        try "{}\n".write(to: root.appendingPathComponent("msplat/build_info.json"), atomically: true, encoding: .utf8)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("msplat build_info.json"), "expected msplat metadata failure; got \(message)")
        }
    }

    func testValidateToolchainRejectsUnexpectedMsplatMetadataKeys() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let buildInfo = root.appendingPathComponent("msplat/build_info.json")
        var payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: buildInfo)) as? [String: Any]
        )
        payload["source_path"] = "/Users/example/private-checkout"
        try JSONSerialization.data(withJSONObject: payload).write(to: buildInfo, options: .atomic)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("unexpected keys"), "expected strict metadata failure; got \(message)")
        }
    }

    func testValidateToolchainRejectsMsplatPayloadHashMismatch() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let binary = root.appendingPathComponent("bin/easysplat-train")
        try Data("tampered binary\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("executable_sha256 mismatch"), "expected native payload hash failure; got \(message)")
        }
    }

    func testValidateToolchainRejectsMalformedMsplatSelfCheckEvents() throws {
        let invalidOutputs = [
            "not json\n",
            "{\"event\":\"self_check\",\"schema_version\":1,\"sequence\":1,\"status\":\"ok\",\"version\":\"1.1.3 (git 106499b)\"}\n{\"event\":\"self_check\"}\n",
            "{\"event\":\"self_check\",\"schema_version\":1,\"sequence\":2,\"status\":\"ok\",\"version\":\"1.1.3 (git 106499b)\"}\n",
            "{\"event\":\"self_check\",\"schema_version\":1,\"sequence\":1,\"status\":\"ok\",\"version\":\"1.1.3\"}\n",
            "{\"event\":\"self_check\",\"schema_version\":1,\"sequence\":1,\"status\":\"ok\",\"version\":\"9.9.9\"}\n",
        ]
        for output in invalidOutputs {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try ToolchainFixtureBuilder.createToolchain(at: root)
            let manager = ToolchainManager(runner: makeValidationRunner(root: root, msplatSelfCheckStdout: output))
            XCTAssertThrowsError(try manager.test_validateToolchain(root: root), "expected rejection for \(output)") { error in
                guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                    return XCTFail("Expected invalidToolchain error")
                }
                XCTAssertTrue(message.contains("self-check"), "expected self-check failure; got \(message)")
            }
        }
    }

    func testValidateToolchainRejectsLegacyMsplatFootprints() throws {
        let legacyPaths = [
            "bin/msplat-train",
            "msplat/bin/msplat-train",
            "msplat/python/bin/python3",
            "msplat/core_extension_path.txt",
            "msplat/python/lib/python3.12/site-packages/msplat/_core.so",
        ]
        for relativePath in legacyPaths {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try ToolchainFixtureBuilder.createToolchain(at: root, includeMsplat: false)
            let legacy = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: legacy.path, contents: Data("legacy".utf8))

            let manager = ToolchainManager(runner: makeValidationRunner(root: root))
            XCTAssertThrowsError(try manager.test_validateToolchain(root: root), "expected legacy rejection for \(relativePath)") { error in
                guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                    return XCTFail("Expected invalidToolchain error, got \(error)")
                }
                XCTAssertTrue(message.contains("legacy msplat"), "expected legacy footprint failure; got \(message)")
            }
        }
    }

    func testValidateToolchainRejectsUnexpectedOrSymlinkedMsplatFiles() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("msplat/unexpected.txt").path,
            contents: Data("unexpected".utf8)
        )
        var manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("unexpected files"), "expected exact closure failure; got \(message)")
        }

        try FileManager.default.removeItem(at: root.appendingPathComponent("msplat/unexpected.txt"))
        let license = root.appendingPathComponent("msplat/LICENSE")
        let target = root.appendingPathComponent("license-target")
        try "Apache License 2.0\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: license)
        try FileManager.default.createSymbolicLink(at: license, withDestinationURL: target)
        manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("symbolic link"), "expected symlink rejection; got \(message)")
        }
    }

    func testValidateToolchainRejectsMsplatExecutableSymlinkWithoutChangingTargetMode() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let executable = root.appendingPathComponent("bin/easysplat-train")
        let target = root.appendingPathComponent("outside-native-binary")
        try Data("fixture native msplat executable\n".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: target)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root))
        let permissions = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testValidateToolchainRejectsSymlinkedMsplatAncestorWithoutChangingTargetMode() throws {
        let root = try TestFileBuilder.makeTempDir()
        let externalBin = root.deletingLastPathComponent()
            .appendingPathComponent("external-bin-(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalBin)
        }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.moveItem(at: bin, to: externalBin)
        try FileManager.default.createSymbolicLink(at: bin, withDestinationURL: externalBin)
        let target = externalBin.appendingPathComponent("easysplat-train")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("symbolic link"), "expected ancestor symlink rejection; got (message)")
        }
        let permissions = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testValidateToolchainRejectsMultiplyLinkedMsplatExecutable() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let executable = root.appendingPathComponent("bin/easysplat-train")
        let externalLink = root.appendingPathComponent("external-native-binary")
        try FileManager.default.linkItem(at: executable, to: externalLink)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("hard link"), "expected hard-link rejection; got (message)")
        }
    }

    func testValidateToolchainRejectsFifoBuildInfoBeforeReading() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let buildInfo = root.appendingPathComponent("msplat/build_info.json")
        try FileManager.default.removeItem(at: buildInfo)
        XCTAssertEqual(Darwin.mkfifo(buildInfo.path, 0o600), 0)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("regular file"), "expected FIFO rejection; got (message)")
        }
    }

    func testValidateToolchainRejectsOversizedMsplatBuildInfoBeforeParsing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let buildInfo = root.appendingPathComponent("msplat/build_info.json")
        try Data(repeating: 0x20, count: 65 * 1_024).write(to: buildInfo, options: .atomic)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("size"), "expected metadata size rejection; got (message)")
        }
    }

    func testValidateToolchainRejectsNonArmNativeMsplat() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root, msplatArch: "Mach-O 64-bit executable x86_64"))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.lowercased().contains("easysplat-train"), "expected native msplat arch failure; got \(message)")
        }
    }

    func testValidateToolchainFailsWhenBrushRealMissing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root, brushHasShebang: true, includeBrushReal: false)

        let runner = makeValidationRunner(root: root)

        let manager = ToolchainManager(runner: runner)
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
            guard case ToolchainManager.ToolchainError.missingBinary(let name) = error else {
                return XCTFail("Expected missingBinary error")
            }
            XCTAssertEqual(name, "brush.real")
        }
    }

    func testValidateToolchainRejectsNonArmPython() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let runner = makeValidationRunner(root: root, vggtPythonArch: "Mach-O 64-bit executable x86_64")

        let manager = ToolchainManager(runner: runner)
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain = error else {
                return XCTFail("Expected invalidToolchain error")
            }
        }
    }

    /// Regression: `/usr/bin/file <path>` echoes the path in stdout, so without `file -b`
    /// a non-Mach-O file under a path containing "arm64" (e.g. `.build/index-build/arm64-apple-macosx/...`)
    /// could spoof the substring check and pass validation. With `-b` the path is stripped
    /// and only the file's actual description is inspected.
    func testValidateToolchainRejectsNonMachOPython() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        // file -b output for a non-Mach-O file. No "arm64" anywhere in the description.
        let runner = makeValidationRunner(root: root, mapAnythingPythonArch: "data")

        let manager = ToolchainManager(runner: runner)
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("Mach-O"), "expected Mach-O check to be the failure reason; got \(message)")
        }
    }

    /// `/usr/bin/file -b` output for a universal Mach-O lists each slice. As long as one
    /// slice is arm64, the binary is usable on Apple silicon.
    func testValidateToolchainAcceptsUniversalArmPython() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root, brushHasShebang: true, includeBrushReal: true)

        let universal = "Mach-O universal binary with 2 architectures: [x86_64:Mach-O 64-bit executable x86_64] [arm64:Mach-O 64-bit executable arm64]"
        let runner = makeValidationRunner(
            root: root,
            brushArchPath: "bin/brush.real",
            da3PythonArch: universal,
            mapAnythingPythonArch: universal,
            vggtPythonArch: universal,
            fastvggtPythonArch: universal,
            msplatArch: universal
        )

        let manager = ToolchainManager(runner: runner)
        XCTAssertNoThrow(try manager.test_validateToolchain(root: root))
    }

    /// A Rosetta-installed colmap would launch via Rosetta on Apple silicon and pass `-h`,
    /// but downstream tools depending on its output format / dylibs misbehave. Fail early.
    func testValidateToolchainRejectsRosettaColmap() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let runner = makeValidationRunner(root: root, colmapArch: "Mach-O 64-bit executable x86_64")

        let manager = ToolchainManager(runner: runner)
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.lowercased().contains("colmap"), "expected colmap-specific message; got \(message)")
        }
    }

    /// When brush is a shebang launcher, the arch check must target brush.real (the actual binary).
    func testValidateToolchainRejectsRosettaBrushReal() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root, brushHasShebang: true, includeBrushReal: true)

        let runner = makeValidationRunner(
            root: root,
            brushArch: "Mach-O 64-bit executable x86_64",
            brushArchPath: "bin/brush.real"
        )

        let manager = ToolchainManager(runner: runner)
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.lowercased().contains("brush"), "expected brush-specific message; got \(message)")
        }
    }

    func testCoreToolchainLooksInstalled() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ToolchainFixtureBuilder.createToolchain(at: root)

        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []))
        XCTAssertTrue(manager.test_coreToolchainLooksInstalled(root: root))

        try FileManager.default.removeItem(at: fixture.libcrypto)
        XCTAssertFalse(manager.test_coreToolchainLooksInstalled(root: root))

        let freshRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: freshRoot) }
        let freshFixture = try ToolchainFixtureBuilder.createToolchain(at: freshRoot)
        XCTAssertTrue(manager.test_coreToolchainLooksInstalled(root: freshRoot))
        try FileManager.default.removeItem(at: freshFixture.da3VendorSentinel)
        XCTAssertFalse(manager.test_coreToolchainLooksInstalled(root: freshRoot))

        let missingMsplatRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: missingMsplatRoot) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: missingMsplatRoot, includeMsplat: false)
        XCTAssertTrue(manager.test_coreToolchainLooksInstalled(root: missingMsplatRoot))

        let partialMsplatRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: partialMsplatRoot) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: partialMsplatRoot)
        XCTAssertTrue(manager.test_coreToolchainLooksInstalled(root: partialMsplatRoot))
        try FileManager.default.removeItem(
            at: partialMsplatRoot.appendingPathComponent("bin/default.metallib")
        )
        XCTAssertFalse(manager.test_coreToolchainLooksInstalled(root: partialMsplatRoot))

        let tamperedMsplatRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tamperedMsplatRoot) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: tamperedMsplatRoot)
        try Data("tampered metallib\n".utf8).write(
            to: tamperedMsplatRoot.appendingPathComponent("bin/default.metallib")
        )
        XCTAssertFalse(manager.test_coreToolchainLooksInstalled(root: tamperedMsplatRoot))

        let legacyMsplatRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: legacyMsplatRoot) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: legacyMsplatRoot, includeMsplat: false)
        FileManager.default.createFile(
            atPath: legacyMsplatRoot.appendingPathComponent("bin/msplat-train").path,
            contents: Data("legacy".utf8)
        )
        XCTAssertFalse(manager.test_coreToolchainLooksInstalled(root: legacyMsplatRoot))
    }

    func testModelsToolchainLooksInstalled() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ToolchainFixtureBuilder.createToolchain(at: root)

        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []))
        XCTAssertTrue(manager.test_modelsToolchainLooksInstalled(root: root))

        try FileManager.default.removeItem(at: fixture.da3ModelFile)
        XCTAssertFalse(manager.test_modelsToolchainLooksInstalled(root: root))
    }

    func testValidateToolchainFailsWhenDa3AppMissing() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(
            at: root,
            includeDa3AppSentinel: false
        )

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        try await withEnvironmentAsync(["EASYSPLAT_SFM_BACKEND": "da3"]) {
            XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
                guard case ToolchainManager.ToolchainError.missingLibrary(let name) = error else {
                    return XCTFail("Expected missingLibrary error")
                }
                XCTAssertEqual(name, "da3_mps/app/easysplat_da3_sfm/run.py")
            }
        }
    }

    func testValidateToolchainFailsWhenDa3ModelMissing() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(
            at: root,
            includeDa3Model: false
        )

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        try await withEnvironmentAsync(["EASYSPLAT_SFM_BACKEND": "da3"]) {
            XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
                guard case ToolchainManager.ToolchainError.missingLibrary(let name) = error else {
                    return XCTFail("Expected missingLibrary error")
                }
                XCTAssertEqual(name, "da3_mps/models/DA3-BASE/model.safetensors")
            }
        }
    }

    func testValidateToolchainFailsWhenDa3ConfigMissing() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ToolchainFixtureBuilder.createToolchain(at: root)
        try FileManager.default.removeItem(at: fixture.da3ConfigFile)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        try await withEnvironmentAsync(["EASYSPLAT_SFM_BACKEND": "da3"]) {
            XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
                guard case ToolchainManager.ToolchainError.missingLibrary(let name) = error else {
                    return XCTFail("Expected missingLibrary error")
                }
                XCTAssertEqual(name, "da3_mps/models/DA3-BASE/config.json")
            }
        }
    }

    func testValidateToolchainFailsWhenDa3ModelInfoMissing() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let info = root.appendingPathComponent("da3_mps/models/DA3-BASE/easysplat_model_info.json")
        try FileManager.default.removeItem(at: info)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        try await withEnvironmentAsync(["EASYSPLAT_SFM_BACKEND": "da3"]) {
            XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
                guard case ToolchainManager.ToolchainError.missingLibrary(let name) = error else {
                    return XCTFail("Expected missingLibrary error")
                }
                XCTAssertEqual(name, "da3_mps/models/DA3-BASE/easysplat_model_info.json")
            }
        }
    }

    func testValidateToolchainFailsWhenDa3FallbackModelMissing() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(
            at: root,
            includeDa3FallbackModel: false
        )

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        try await withEnvironmentAsync(["EASYSPLAT_SFM_BACKEND": "da3"]) {
            XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
                guard case ToolchainManager.ToolchainError.missingLibrary(let name) = error else {
                    return XCTFail("Expected missingLibrary error")
                }
                XCTAssertEqual(name, "da3_mps/models/DA3-SMALL/model.safetensors")
            }
        }
    }

    func testValidateToolchainRejectsNonArmDa3Python() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root, da3PythonArch: "Mach-O 64-bit executable x86_64"))
        try await withEnvironmentAsync(["EASYSPLAT_SFM_BACKEND": "da3"]) {
            XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
                guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                    return XCTFail("Expected invalidToolchain error")
                }
                XCTAssertTrue(message.lowercased().contains("da3_mps python"), "expected DA3-specific message; got \(message)")
            }
        }
    }

    func testValidateToolchainFailsWhenDa3HelpFails() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root, da3HelpExitCode: 2))
        try await withEnvironmentAsync(["EASYSPLAT_SFM_BACKEND": "da3"]) {
            XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
                guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                    return XCTFail("Expected invalidToolchain error")
                }
                XCTAssertTrue(message.contains("da3_mps failed to launch"), "expected DA3 launch failure; got \(message)")
            }
        }
    }

    func testValidateToolchainFailsWhenDa3BuildInfoMissing() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ToolchainFixtureBuilder.createToolchain(at: root)
        try FileManager.default.removeItem(at: fixture.da3BuildInfo)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        try await withEnvironmentAsync(["EASYSPLAT_SFM_BACKEND": "da3"]) {
            XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
                guard case ToolchainManager.ToolchainError.missingLibrary(let name) = error else {
                    return XCTFail("Expected missingLibrary error")
                }
                XCTAssertEqual(name, "da3_mps/build_info.json")
            }
        }
    }

    func testValidateToolchainAllowsExplicitColmapWithoutDa3Bundle() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("da3_mps", isDirectory: true))

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        try await withEnvironmentAsync(["EASYSPLAT_SFM_BACKEND": "colmap"]) {
            XCTAssertNoThrow(try manager.test_validateToolchain(root: root))
        }
    }

    func testValidateToolchainFailsWhenMapAnythingAppMissing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(
            at: root,
            includeMapAnythingAppSentinel: false
        )

        let runner = makeValidationRunner(root: root)

        let manager = ToolchainManager(runner: runner)
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
            guard case ToolchainManager.ToolchainError.missingLibrary(let name) = error else {
                return XCTFail("Expected missingLibrary error")
            }
            XCTAssertEqual(name, "mapanything_mps/app/easysplat_mapanything_sfm/run.py")
        }
    }

    func testValidateToolchainFailsWhenMapAnythingBuildInfoMissing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ToolchainFixtureBuilder.createToolchain(at: root)
        try FileManager.default.removeItem(at: fixture.mapanythingBuildInfo)

        let runner = makeValidationRunner(root: root)

        let manager = ToolchainManager(runner: runner)
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
            guard case ToolchainManager.ToolchainError.missingLibrary(let name) = error else {
                return XCTFail("Expected missingLibrary error")
            }
            XCTAssertEqual(name, "mapanything_mps/build_info.json")
        }
    }

    func testFileHasShebang() throws {
        let dir = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("script")
        let data = Data([0x23, 0x21, 0x2f, 0x62])
        TestFileBuilder.createFile(at: script, data: data)
        let plain = dir.appendingPathComponent("plain")
        TestFileBuilder.createFile(at: plain, data: Data([0x00, 0x01]))

        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []))
        XCTAssertTrue(manager.test_fileHasShebang(at: script))
        XCTAssertFalse(manager.test_fileHasShebang(at: plain))
    }

    func testValidateToolchainFailsWhenVggtBuildInfoMissing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ToolchainFixtureBuilder.createToolchain(at: root)
        try FileManager.default.removeItem(at: fixture.vggtBuildInfo)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
            guard case ToolchainManager.ToolchainError.missingLibrary(let name) = error else {
                return XCTFail("Expected missingLibrary error")
            }
            XCTAssertEqual(name, "vggt_mps/build_info.json")
        }
    }

    func testValidateToolchainFailsWhenFastVggtBuildInfoMissing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ToolchainFixtureBuilder.createToolchain(at: root)
        try FileManager.default.removeItem(at: fixture.fastvggtBuildInfo)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
            guard case ToolchainManager.ToolchainError.missingLibrary(let name) = error else {
                return XCTFail("Expected missingLibrary error")
            }
            XCTAssertEqual(name, "fastvggt_mps/build_info.json")
        }
    }

    func testValidateToolchainRejectsMalformedBuildInfo() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ToolchainFixtureBuilder.createToolchain(at: root)
        try "[]\n".write(to: fixture.mapanythingBuildInfo, atomically: true, encoding: .utf8)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("mapanything_mps build_info.json"))
        }
    }

    func testValidateToolchainRejectsBrokenPythonWrapper() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root, mapAnythingHelpExitCode: 1))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root)) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("mapanything_mps failed to launch"))
        }
    }

    func testEnsureToolchainUsesLocalOverride() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let runner = makeValidationRunner(root: root)

        try await withEnvironmentAsync(["EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": root.path]) {
            let manager = ToolchainManager(runner: runner)
            let manifestURL = URL(string: "https://example.com/manifest.json")!
            let toolchain = try await manager.ensureToolchain(manifestURL: manifestURL, publicKeyBase64: "ignored", targetName: "macos-arm64") { _, _ in }
            XCTAssertEqual(toolchain.root, root)
        }
    }

    private func makeValidationRunner(
        root: URL,
        colmapArch: String = "Mach-O 64-bit executable arm64",
        brushArch: String = "Mach-O 64-bit executable arm64",
        brushArchPath: String = "bin/brush",
        da3PythonArch: String = "Mach-O 64-bit executable arm64",
        mapAnythingPythonArch: String = "Mach-O 64-bit executable arm64",
        vggtPythonArch: String = "Mach-O 64-bit executable arm64",
        fastvggtPythonArch: String = "Mach-O 64-bit executable arm64",
        msplatArch: String = "Mach-O 64-bit executable arm64",
        da3HelpExitCode: Int32 = 0,
        mapAnythingHelpExitCode: Int32 = 0,
        vggtHelpExitCode: Int32 = 0,
        fastvggtHelpExitCode: Int32 = 0,
        msplatSelfCheckExitCode: Int32 = 0,
        msplatSelfCheckStdout: String = "{\"event\":\"self_check\",\"schema_version\":1,\"sequence\":1,\"status\":\"ok\",\"version\":\"1.1.3 (git 106499b)\"}\n"
    ) -> MockSubprocessRunner {
        MockSubprocessRunner(scripts: [
            .init(path: "/usr/bin/file", argsPrefix: ["-b", root.appendingPathComponent("bin/colmap").path], result: .init(exitCode: 0, terminationReason: .exit, stdout: colmapArch, stderr: ""), onRun: nil),
            .init(path: "/usr/bin/file", argsPrefix: ["-b", root.appendingPathComponent(brushArchPath).path], result: .init(exitCode: 0, terminationReason: .exit, stdout: brushArch, stderr: ""), onRun: nil),
            .init(path: root.appendingPathComponent("bin/colmap").path, argsPrefix: ["-h"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: root.appendingPathComponent("bin/brush").path, argsPrefix: ["--help"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/usr/bin/file", argsPrefix: ["-b", root.appendingPathComponent("da3_mps/python/bin/python3").path], result: .init(exitCode: 0, terminationReason: .exit, stdout: da3PythonArch, stderr: ""), onRun: nil),
            .init(path: root.appendingPathComponent("da3_mps/bin/easysplat_da3_sfm").path, argsPrefix: ["--help"], result: .init(exitCode: da3HelpExitCode, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/usr/bin/file", argsPrefix: ["-b", root.appendingPathComponent("mapanything_mps/python/bin/python3").path], result: .init(exitCode: 0, terminationReason: .exit, stdout: mapAnythingPythonArch, stderr: ""), onRun: nil),
            .init(path: root.appendingPathComponent("mapanything_mps/bin/easysplat_mapanything_sfm").path, argsPrefix: ["--help"], result: .init(exitCode: mapAnythingHelpExitCode, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/usr/bin/file", argsPrefix: ["-b", root.appendingPathComponent("vggt_mps/python/bin/python3").path], result: .init(exitCode: 0, terminationReason: .exit, stdout: vggtPythonArch, stderr: ""), onRun: nil),
            .init(path: root.appendingPathComponent("vggt_mps/bin/easysplat_vggt_sfm").path, argsPrefix: ["--help"], result: .init(exitCode: vggtHelpExitCode, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/usr/bin/file", argsPrefix: ["-b", root.appendingPathComponent("fastvggt_mps/python/bin/python3").path], result: .init(exitCode: 0, terminationReason: .exit, stdout: fastvggtPythonArch, stderr: ""), onRun: nil),
            .init(path: root.appendingPathComponent("fastvggt_mps/bin/easysplat_fastvggt_sfm").path, argsPrefix: ["--help"], result: .init(exitCode: fastvggtHelpExitCode, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/usr/bin/file", argsPrefix: ["-b", root.appendingPathComponent("bin/easysplat-train").path], result: .init(exitCode: 0, terminationReason: .exit, stdout: msplatArch, stderr: ""), onRun: nil),
            .init(
                path: root.appendingPathComponent("bin/easysplat-train").path,
                argsPrefix: ["--self-check", "--events-fd", "1"],
                result: .init(
                    exitCode: msplatSelfCheckExitCode,
                    terminationReason: .exit,
                    stdout: msplatSelfCheckStdout,
                    stderr: ""
                ),
                onRun: nil
            )
        ])
    }
}
