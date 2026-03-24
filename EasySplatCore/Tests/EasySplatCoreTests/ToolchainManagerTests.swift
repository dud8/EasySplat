import XCTest
@testable import EasySplatCore

@MainActor
final class ToolchainManagerTests: XCTestCase {
    func testValidateToolchainSucceeds() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root, brushHasShebang: true, includeBrushReal: true)

        let runner = makeValidationRunner(root: root)

        let manager = ToolchainManager(runner: runner)
        let toolchain = try manager.test_validateToolchain(root: root)
        XCTAssertEqual(toolchain.root, root)
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

    func testCoreToolchainLooksInstalled() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ToolchainFixtureBuilder.createToolchain(at: root)

        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []))
        XCTAssertTrue(manager.test_coreToolchainLooksInstalled(root: root))

        try FileManager.default.removeItem(at: fixture.libcrypto)
        XCTAssertFalse(manager.test_coreToolchainLooksInstalled(root: root))
    }

    func testModelsToolchainLooksInstalled() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ToolchainFixtureBuilder.createToolchain(at: root)

        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []))
        XCTAssertTrue(manager.test_modelsToolchainLooksInstalled(root: root))

        try FileManager.default.removeItem(at: fixture.vggtModelFile)
        XCTAssertFalse(manager.test_modelsToolchainLooksInstalled(root: root))
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
        mapAnythingPythonArch: String = "Mach-O 64-bit executable arm64",
        vggtPythonArch: String = "Mach-O 64-bit executable arm64",
        fastvggtPythonArch: String = "Mach-O 64-bit executable arm64",
        mapAnythingHelpExitCode: Int32 = 0,
        vggtHelpExitCode: Int32 = 0,
        fastvggtHelpExitCode: Int32 = 0
    ) -> MockSubprocessRunner {
        MockSubprocessRunner(scripts: [
            .init(path: root.appendingPathComponent("bin/colmap").path, argsPrefix: ["-h"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: root.appendingPathComponent("bin/brush").path, argsPrefix: ["--help"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/usr/bin/file", argsPrefix: [root.appendingPathComponent("mapanything_mps/python/bin/python3").path], result: .init(exitCode: 0, terminationReason: .exit, stdout: mapAnythingPythonArch, stderr: ""), onRun: nil),
            .init(path: root.appendingPathComponent("mapanything_mps/bin/easysplat_mapanything_sfm").path, argsPrefix: ["--help"], result: .init(exitCode: mapAnythingHelpExitCode, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/usr/bin/file", argsPrefix: [root.appendingPathComponent("vggt_mps/python/bin/python3").path], result: .init(exitCode: 0, terminationReason: .exit, stdout: vggtPythonArch, stderr: ""), onRun: nil),
            .init(path: root.appendingPathComponent("vggt_mps/bin/easysplat_vggt_sfm").path, argsPrefix: ["--help"], result: .init(exitCode: vggtHelpExitCode, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/usr/bin/file", argsPrefix: [root.appendingPathComponent("fastvggt_mps/python/bin/python3").path], result: .init(exitCode: 0, terminationReason: .exit, stdout: fastvggtPythonArch, stderr: ""), onRun: nil),
            .init(path: root.appendingPathComponent("fastvggt_mps/bin/easysplat_fastvggt_sfm").path, argsPrefix: ["--help"], result: .init(exitCode: fastvggtHelpExitCode, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil)
        ])
    }
}
