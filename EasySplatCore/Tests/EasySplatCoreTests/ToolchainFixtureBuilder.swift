import Foundation
@testable import EasySplatCore

struct ToolchainFixture {
    let root: URL
    let colmap: URL
    let glomap: URL
    let brush: URL
    let brushReal: URL
    let libcrypto: URL
    let libssl: URL
    let vggtRoot: URL
    let vggtSfmTool: URL
    let vggtPython: URL
    let vggtModels: URL
    let vggtModelFile: URL
    let vggtVendorSentinel: URL
}

enum ToolchainFixtureBuilder {
    static func createToolchain(
        at root: URL,
        brushHasShebang: Bool = false,
        includeBrushReal: Bool = true,
        includeVggtModel: Bool = true,
        includeVendorSentinel: Bool = true
    ) throws -> ToolchainFixture {
        let fm = FileManager.default
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let lib = root.appendingPathComponent("lib", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: lib, withIntermediateDirectories: true)

        func writeExecutable(_ url: URL, script: String?) throws {
            if let script {
                try script.write(to: url, atomically: true, encoding: .utf8)
            } else {
                fm.createFile(atPath: url.path, contents: Data())
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        let colmap = bin.appendingPathComponent("colmap")
        let glomap = bin.appendingPathComponent("glomap")
        let brush = bin.appendingPathComponent("brush")
        let brushReal = bin.appendingPathComponent("brush.real")
        try writeExecutable(colmap, script: "#!/usr/bin/env bash\nexit 0\n")
        try writeExecutable(glomap, script: "#!/usr/bin/env bash\nexit 0\n")
        if brushHasShebang {
            try writeExecutable(brush, script: "#!/usr/bin/env bash\nexit 0\n")
            if includeBrushReal {
                try writeExecutable(brushReal, script: "#!/usr/bin/env bash\nexit 0\n")
            }
        } else {
            try writeExecutable(brush, script: nil)
        }

        let libcrypto = lib.appendingPathComponent("libcrypto.3.dylib")
        let libssl = lib.appendingPathComponent("libssl.3.dylib")
        fm.createFile(atPath: libcrypto.path, contents: Data())
        fm.createFile(atPath: libssl.path, contents: Data())

        let vggtRoot = root.appendingPathComponent("vggt_mps", isDirectory: true)
        let vggtSfmTool = vggtRoot.appendingPathComponent("bin/easysplat_vggt_sfm")
        let vggtPython = vggtRoot.appendingPathComponent("python/bin/python3")
        let vggtModels = vggtRoot.appendingPathComponent("models", isDirectory: true)
        let vggtModelFile = vggtModels.appendingPathComponent("vggt_model.pt")
        let vggtVendorSentinel = vggtRoot.appendingPathComponent("vendor/vggt/vggt/models/vggt.py")

        try fm.createDirectory(at: vggtSfmTool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: vggtPython.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: vggtModels, withIntermediateDirectories: true)
        try fm.createDirectory(at: vggtVendorSentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeExecutable(vggtSfmTool, script: "#!/usr/bin/env bash\nexit 0\n")
        try writeExecutable(vggtPython, script: "#!/usr/bin/env bash\necho python\n")
        if includeVggtModel {
            fm.createFile(atPath: vggtModelFile.path, contents: Data([0x00]))
        }
        if includeVendorSentinel {
            fm.createFile(atPath: vggtVendorSentinel.path, contents: Data([0x00]))
        }

        return ToolchainFixture(
            root: root,
            colmap: colmap,
            glomap: glomap,
            brush: brush,
            brushReal: brushReal,
            libcrypto: libcrypto,
            libssl: libssl,
            vggtRoot: vggtRoot,
            vggtSfmTool: vggtSfmTool,
            vggtPython: vggtPython,
            vggtModels: vggtModels,
            vggtModelFile: vggtModelFile,
            vggtVendorSentinel: vggtVendorSentinel
        )
    }

    static func makeToolchainPaths(from fixture: ToolchainFixture) -> ToolchainPaths {
        let vggt = VggtToolchain(
            root: fixture.vggtRoot,
            sfmTool: fixture.vggtSfmTool,
            python: fixture.vggtPython,
            models: fixture.vggtModels
        )
        return ToolchainPaths(
            root: fixture.root,
            colmap: fixture.colmap,
            glomap: fixture.glomap,
            brush: fixture.brush,
            vggt: vggt,
            learnedSfm: nil
        )
    }
}
