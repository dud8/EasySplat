import Foundation
@testable import EasySplatCore

enum TestToolchains {
    static func mapAnythingToolchain(root: URL, createFiles: Bool = false) throws -> MapAnythingToolchain {
        let mapRoot = root.appendingPathComponent("mapanything_mps", isDirectory: true)
        let sfmTool = mapRoot.appendingPathComponent("bin/easysplat_mapanything_sfm")
        let python = mapRoot.appendingPathComponent("python/bin/python3")
        let models = mapRoot.appendingPathComponent("models", isDirectory: true)
        let modelBundle = models.appendingPathComponent("map-anything-apache", isDirectory: true)
        let dinov2Weights = models.appendingPathComponent("dinov2/dinov2_vitg14_pretrain.pth")
        let buildInfo = mapRoot.appendingPathComponent("build_info.json")
        let appDir = mapRoot.appendingPathComponent("app/easysplat_mapanything_sfm", isDirectory: true)

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
            try fm.createDirectory(at: modelBundle, withIntermediateDirectories: true)
            try fm.createDirectory(at: dinov2Weights.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
            try """
            {
              "toolchain_name": "mapanything_mps",
              "source_path": "test-fixture",
              "python_version": "3.13.11",
              "torch_version": "2.10.0",
              "torchvision_version": "0.25.0"
            }
            """.write(to: buildInfo, atomically: true, encoding: .utf8)
            let stub = "{}\n"
            try stub.write(to: modelBundle.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
            fm.createFile(atPath: modelBundle.appendingPathComponent("model.safetensors").path, contents: Data([0x00]))
            fm.createFile(atPath: dinov2Weights.path, contents: Data([0x00]))
            try "# placeholder\n".write(to: appDir.appendingPathComponent("run.py"), atomically: true, encoding: .utf8)
        }

        return MapAnythingToolchain(
            root: mapRoot,
            sfmTool: sfmTool,
            python: python,
            models: models,
            modelBundle: modelBundle,
            dinov2Weights: dinov2Weights
        )
    }

    static func vggtToolchain(root: URL, createFiles: Bool = false) throws -> VggtToolchain {
        let vggtRoot = root.appendingPathComponent("vggt_mps", isDirectory: true)
        let sfmTool = vggtRoot.appendingPathComponent("bin/easysplat_vggt_sfm")
        let python = vggtRoot.appendingPathComponent("python/bin/python3")
        let buildInfo = vggtRoot.appendingPathComponent("build_info.json")
        let models = vggtRoot.appendingPathComponent("models", isDirectory: true)
        let appDir = vggtRoot.appendingPathComponent("app/easysplat_vggt_sfm", isDirectory: true)

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
            try """
            {
              "toolchain_name": "vggt_mps",
              "source_path": "test-fixture",
              "python_version": "3.13.11",
              "torch_version": "2.10.0",
              "torchvision_version": "0.25.0"
            }
            """.write(to: buildInfo, atomically: true, encoding: .utf8)
            try "# placeholder\n".write(to: appDir.appendingPathComponent("run.py"), atomically: true, encoding: .utf8)
        }

        return VggtToolchain(root: vggtRoot, sfmTool: sfmTool, python: python, models: models)
    }

    static func fastVggtToolchain(root: URL, createFiles: Bool = false) throws -> FastVggtToolchain {
        let fastRoot = root.appendingPathComponent("fastvggt_mps", isDirectory: true)
        let sfmTool = fastRoot.appendingPathComponent("bin/easysplat_fastvggt_sfm")
        let python = fastRoot.appendingPathComponent("python/bin/python3")
        let buildInfo = fastRoot.appendingPathComponent("build_info.json")
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
            try """
            {
              "toolchain_name": "fastvggt_mps",
              "source_path": "test-fixture",
              "python_version": "3.13.11",
              "torch_version": "2.10.0",
              "torchvision_version": "0.25.0"
            }
            """.write(to: buildInfo, atomically: true, encoding: .utf8)
            let stub = "# placeholder\n"
            try stub.write(to: appDir.appendingPathComponent("run.py"), atomically: true, encoding: .utf8)
        }

        return FastVggtToolchain(root: fastRoot, sfmTool: sfmTool, python: python, models: models)
    }
}
