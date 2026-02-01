import XCTest
@testable import EasySplatCore

@MainActor
final class ToolchainManagerTests: XCTestCase {
    func testValidateToolchainSucceeds() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root, brushHasShebang: true, includeBrushReal: true)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: root.appendingPathComponent("bin/colmap").path, argsPrefix: ["-h"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: root.appendingPathComponent("bin/glomap").path, argsPrefix: ["--help"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: root.appendingPathComponent("bin/brush").path, argsPrefix: ["--help"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/usr/bin/file", argsPrefix: [root.appendingPathComponent("vggt_mps/python/bin/python3").path], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Mach-O 64-bit executable arm64", stderr: ""), onRun: nil)
        ])

        let manager = ToolchainManager(runner: runner)
        let toolchain = try manager.test_validateToolchain(root: root)
        XCTAssertEqual(toolchain.root, root)
    }

    func testValidateToolchainFailsWhenBrushRealMissing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root, brushHasShebang: true, includeBrushReal: false)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: root.appendingPathComponent("bin/colmap").path, argsPrefix: ["-h"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: root.appendingPathComponent("bin/glomap").path, argsPrefix: ["--help"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: root.appendingPathComponent("bin/brush").path, argsPrefix: ["--help"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/usr/bin/file", argsPrefix: [root.appendingPathComponent("vggt_mps/python/bin/python3").path], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Mach-O 64-bit executable arm64", stderr: ""), onRun: nil)
        ])

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

        let runner = MockSubprocessRunner(scripts: [
            .init(path: root.appendingPathComponent("bin/colmap").path, argsPrefix: ["-h"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: root.appendingPathComponent("bin/glomap").path, argsPrefix: ["--help"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: root.appendingPathComponent("bin/brush").path, argsPrefix: ["--help"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/usr/bin/file", argsPrefix: [root.appendingPathComponent("vggt_mps/python/bin/python3").path], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Mach-O 64-bit executable x86_64", stderr: ""), onRun: nil)
        ])

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

    func testEnsureToolchainUsesLocalOverride() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        setenv("EASYSPLAT_LOCAL_TOOLCHAIN_ROOT", root.path, 1)
        defer { unsetenv("EASYSPLAT_LOCAL_TOOLCHAIN_ROOT") }

        let runner = MockSubprocessRunner(scripts: [
            .init(path: root.appendingPathComponent("bin/colmap").path, argsPrefix: ["-h"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: root.appendingPathComponent("bin/glomap").path, argsPrefix: ["--help"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: root.appendingPathComponent("bin/brush").path, argsPrefix: ["--help"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/usr/bin/file", argsPrefix: [root.appendingPathComponent("vggt_mps/python/bin/python3").path], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Mach-O 64-bit executable arm64", stderr: ""), onRun: nil)
        ])

        let manager = ToolchainManager(runner: runner)
        let manifestURL = URL(string: "https://example.com/manifest.json")!
        let toolchain = try await manager.ensureToolchain(manifestURL: manifestURL, publicKeyBase64: "ignored", targetName: "macos-arm64") { _, _ in }
        XCTAssertEqual(toolchain.root, root)
    }
}
