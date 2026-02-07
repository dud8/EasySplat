import Foundation
@testable import EasySplatCore

enum TestToolchains {
    static func vggtToolchain(root: URL, createFiles: Bool = false) throws -> VggtToolchain {
        let vggtRoot = root.appendingPathComponent("vggt_mps", isDirectory: true)
        let sfmTool = vggtRoot.appendingPathComponent("bin/easysplat_vggt_sfm")
        let python = vggtRoot.appendingPathComponent("python/bin/python3")
        let models = vggtRoot.appendingPathComponent("models", isDirectory: true)

        if createFiles {
            let fm = FileManager.default
            try fm.createDirectory(at: sfmTool.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: sfmTool.path, contents: Data())
            try fm.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
            let pythonStub = [
                "#!/usr/bin/env bash",
                "echo 'python stub'",
                ""
            ].joined(separator: "\n")
            try pythonStub.write(to: python, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
            try fm.createDirectory(at: models, withIntermediateDirectories: true)
        }

        return VggtToolchain(root: vggtRoot, sfmTool: sfmTool, python: python, models: models)
    }

    static func fastVggtToolchain(root: URL, createFiles: Bool = false) throws -> FastVggtToolchain {
        let fastRoot = root.appendingPathComponent("fastvggt_mps", isDirectory: true)
        let sfmTool = fastRoot.appendingPathComponent("bin/easysplat_fastvggt_sfm")
        let python = fastRoot.appendingPathComponent("python/bin/python3")
        let models = fastRoot.appendingPathComponent("models", isDirectory: true)
        let appDir = fastRoot.appendingPathComponent("app/easysplat_fastvggt_sfm", isDirectory: true)

        if createFiles {
            let fm = FileManager.default
            try fm.createDirectory(at: sfmTool.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: sfmTool.path, contents: Data())
            try fm.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
            let pythonStub = [
                "#!/usr/bin/env bash",
                "echo 'python stub'",
                ""
            ].joined(separator: "\n")
            try pythonStub.write(to: python, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
            try fm.createDirectory(at: models, withIntermediateDirectories: true)
            try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
            let stub = "# placeholder\n"
            try stub.write(to: appDir.appendingPathComponent("run.py"), atomically: true, encoding: .utf8)
        }

        return FastVggtToolchain(root: fastRoot, sfmTool: sfmTool, python: python, models: models)
    }
}
