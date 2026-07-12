import Foundation
@testable import EasySplatCore

enum TestToolchains {
    static func toolchainPaths(root: URL, colmap: URL? = nil, msplat: URL? = nil) -> ToolchainPaths {
        let da3Root = root.appendingPathComponent("da3_mps", isDirectory: true)
        let models = da3Root.appendingPathComponent("models", isDirectory: true)
        let da3 = Da3Toolchain(
            root: da3Root,
            sfmTool: da3Root.appendingPathComponent("bin/easysplat_da3_sfm"),
            python: da3Root.appendingPathComponent("python/bin/python3"),
            models: models,
            modelBundle: models.appendingPathComponent("DA3-BASE", isDirectory: true),
            fallbackModelBundle: models.appendingPathComponent("DA3-SMALL", isDirectory: true)
        )
        return ToolchainPaths(
            root: root,
            colmap: colmap ?? root,
            msplat: msplat ?? root.appendingPathComponent("bin/easysplat-train"),
            da3: da3
        )
    }

    static func da3Toolchain(root: URL, createFiles: Bool = false) throws -> Da3Toolchain {
        let da3Root = root.appendingPathComponent("da3_mps", isDirectory: true)
        let sfmTool = da3Root.appendingPathComponent("bin/easysplat_da3_sfm")
        let python = da3Root.appendingPathComponent("python/bin/python3")
        let buildInfo = da3Root.appendingPathComponent("build_info.json")
        let models = da3Root.appendingPathComponent("models", isDirectory: true)
        let modelBundle = models.appendingPathComponent("DA3-BASE", isDirectory: true)
        let fallbackModelBundle = models.appendingPathComponent("DA3-SMALL", isDirectory: true)
        let appDir = da3Root.appendingPathComponent("app/easysplat_da3_sfm", isDirectory: true)

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
            try fm.createDirectory(at: fallbackModelBundle, withIntermediateDirectories: true)
            try fm.createDirectory(at: appDir, withIntermediateDirectories: true)
            try """
            {
              "toolchain_name": "da3_mps",
              "source_path": "test-fixture",
              "python_version": "3.13.11",
              "torch_version": "2.10.0",
              "torchvision_version": "0.25.0"
            }
            """.write(to: buildInfo, atomically: true, encoding: .utf8)
            for modelDir in [modelBundle, fallbackModelBundle] {
                try "{}\n".write(to: modelDir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
                fm.createFile(atPath: modelDir.appendingPathComponent("model.safetensors").path, contents: Data([0x00]))
                try #"{"repo_id":"fixture","resolved_sha":"fixture","license":"apache-2.0"}"#.write(
                    to: modelDir.appendingPathComponent("easysplat_model_info.json"),
                    atomically: true,
                    encoding: .utf8
                )
            }
            try "# placeholder\n".write(to: appDir.appendingPathComponent("run.py"), atomically: true, encoding: .utf8)
        }

        return Da3Toolchain(
            root: da3Root,
            sfmTool: sfmTool,
            python: python,
            models: models,
            modelBundle: modelBundle,
            fallbackModelBundle: fallbackModelBundle
        )
    }
}
