import CryptoKit
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
    let da3Root: URL
    let da3SfmTool: URL
    let da3Python: URL
    let da3BuildInfo: URL
    let da3AppSentinel: URL
    let da3Models: URL
    let da3ModelBundle: URL
    let da3ModelFile: URL
    let da3ConfigFile: URL
    let da3FallbackModelBundle: URL
    let da3FallbackModelFile: URL
    let da3FallbackConfigFile: URL
    let da3VendorSentinel: URL
    let mapanythingRoot: URL
    let mapanythingSfmTool: URL
    let mapanythingPython: URL
    let mapanythingBuildInfo: URL
    let mapanythingAppSentinel: URL
    let mapanythingModels: URL
    let mapanythingModelBundle: URL
    let mapanythingModelFile: URL
    let mapanythingConfigFile: URL
    let mapanythingDinov2Weights: URL
    let mapanythingVendorSentinel: URL
    let vggtRoot: URL
    let vggtSfmTool: URL
    let vggtPython: URL
    let vggtBuildInfo: URL
    let vggtAppSentinel: URL
    let vggtModels: URL
    let vggtModelFile: URL
    let vggtVendorSentinel: URL
    let fastvggtRoot: URL
    let fastvggtSfmTool: URL
    let fastvggtPython: URL
    let fastvggtBuildInfo: URL
    let fastvggtAppSentinel: URL
    let fastvggtModels: URL
    let fastvggtModelFile: URL
    let fastvggtVendorSentinel: URL
}

enum ToolchainFixtureBuilder {
    static func createToolchain(
        at root: URL,
        brushHasShebang: Bool = false,
        includeBrushReal: Bool = true,
        includeDa3Model: Bool = true,
        includeDa3FallbackModel: Bool = true,
        includeDa3AppSentinel: Bool = true,
        includeDa3VendorSentinel: Bool = true,
        includeMapAnythingModel: Bool = true,
        includeMapAnythingAppSentinel: Bool = true,
        includeMapAnythingVendorSentinel: Bool = true,
        includeVggtModel: Bool = true,
        includeVggtBuildInfo: Bool = true,
        includeVggtAppSentinel: Bool = true,
        includeVendorSentinel: Bool = true,
        includeFastVggtModel: Bool = true,
        includeFastVggtBuildInfo: Bool = true,
        includeFastVggtAppSentinel: Bool = true,
        includeFastVggtVendorSentinel: Bool = true,
        includeMsplat: Bool = true
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

        if includeMsplat {
            let msplat = bin.appendingPathComponent("easysplat-train")
            let metallib = bin.appendingPathComponent("default.metallib")
            let msplatRoot = root.appendingPathComponent("msplat", isDirectory: true)
            let msplatBuildInfo = msplatRoot.appendingPathComponent("build_info.json")
            let msplatLicense = msplatRoot.appendingPathComponent("LICENSE")
            try fm.createDirectory(at: msplatRoot, withIntermediateDirectories: true)

            let executableData = Data("fixture native msplat executable\n".utf8)
            let metallibData = Data("fixture Metal library\n".utf8)
            fm.createFile(atPath: msplat.path, contents: executableData)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: msplat.path)
            fm.createFile(atPath: metallib.path, contents: metallibData)
            try "Apache License 2.0\n".write(to: msplatLicense, atomically: true, encoding: .utf8)

            let hex: (Data) -> String = { data in
                SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            let payload: [String: Any] = [
                "toolchain_name": "msplat",
                "source_url": "https://github.com/rayanht/msplat.git",
                "source_commit": "106499b0a53f82b0c92d013b0861fbebd341b17e",
                "source_version": "1.1.3",
                "source_tree_sha256": String(repeating: "a", count: 64),
                "overlay_sha256": String(repeating: "b", count: 64),
                "patch_sha256": String(repeating: "c", count: 64),
                "checkpoint_patch_sha256": String(repeating: "d", count: 64),
                "dependencies": [
                    "nlohmann_json_v3.11.3_sha256": "04022b05d806eb5ff73023c280b68697d12b93e1b7267a0b22a1a39ec7578069",
                    "nanoflann_v1.5.5_sha256": "57496cb27e1310a77a367e5a902c8f1c700496d91ac54ccc87fbe9ccc28bc6cc",
                    "cli11_v2.4.2_sha256": "43e650d5e1a3acaaf419d1e61a81f77b408d0696f472be0599ddf877d40984b0",
                ],
                "executable_sha256": hex(executableData),
                "metallib_sha256": hex(metallibData),
                "compiler": "Apple clang fixture",
                "cmake": "cmake version fixture",
                "ninja": "fixture",
                "deployment_target": "macOS 15.0",
                "build_configuration": "Release",
                "cmake_arguments": [
                    "-G Ninja",
                    "-DCMAKE_BUILD_TYPE=Release",
                    "-DCMAKE_OSX_ARCHITECTURES=arm64",
                    "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0",
                    "-DMSPLAT_BUILD_PYTHON=OFF",
                    "-DFETCHCONTENT_FULLY_DISCONNECTED=ON",
                    "FETCHCONTENT_SOURCE_DIR_NLOHMANN_JSON=verified-v3.11.3",
                    "FETCHCONTENT_SOURCE_DIR_NANOFLANN=verified-v1.5.5",
                    "FETCHCONTENT_SOURCE_DIR_CLI11=verified-v2.4.2",
                ],
                "build_timestamp": "2026-07-11T00:00:00Z",
            ]
            let buildInfoData = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try buildInfoData.write(to: msplatBuildInfo, options: .atomic)
        }

        let da3Root = root.appendingPathComponent("da3_mps", isDirectory: true)
        let da3SfmTool = da3Root.appendingPathComponent("bin/easysplat_da3_sfm")
        let da3Python = da3Root.appendingPathComponent("python/bin/python3")
        let da3BuildInfo = da3Root.appendingPathComponent("build_info.json")
        let da3AppSentinel = da3Root.appendingPathComponent("app/easysplat_da3_sfm/run.py")
        let da3Models = da3Root.appendingPathComponent("models", isDirectory: true)
        let da3ModelBundle = da3Models.appendingPathComponent("DA3-BASE", isDirectory: true)
        let da3ModelFile = da3ModelBundle.appendingPathComponent("model.safetensors")
        let da3ConfigFile = da3ModelBundle.appendingPathComponent("config.json")
        let da3ModelInfoFile = da3ModelBundle.appendingPathComponent("easysplat_model_info.json")
        let da3FallbackModelBundle = da3Models.appendingPathComponent("DA3-SMALL", isDirectory: true)
        let da3FallbackModelFile = da3FallbackModelBundle.appendingPathComponent("model.safetensors")
        let da3FallbackConfigFile = da3FallbackModelBundle.appendingPathComponent("config.json")
        let da3FallbackModelInfoFile = da3FallbackModelBundle.appendingPathComponent("easysplat_model_info.json")
        let da3VendorSentinel = da3Root.appendingPathComponent("vendor/depth-anything-3/src/depth_anything_3/api.py")

        try fm.createDirectory(at: da3SfmTool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: da3Python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: da3AppSentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: da3ModelBundle, withIntermediateDirectories: true)
        try fm.createDirectory(at: da3FallbackModelBundle, withIntermediateDirectories: true)
        try fm.createDirectory(at: da3VendorSentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeExecutable(da3SfmTool, script: "#!/usr/bin/env bash\nexit 0\n")
        try writeExecutable(da3Python, script: "#!/usr/bin/env bash\necho python\n")
        try """
        {
          "toolchain_name": "da3_mps",
          "source_path": "fixture",
          "python_version": "3.13.11",
          "torch_version": "2.10.0",
          "torchvision_version": "0.25.0"
        }
        """.write(to: da3BuildInfo, atomically: true, encoding: .utf8)
        if includeDa3AppSentinel {
            try "from __future__ import annotations\n".write(to: da3AppSentinel, atomically: true, encoding: .utf8)
        }
        if includeDa3Model {
            fm.createFile(atPath: da3ModelFile.path, contents: Data([0x00]))
            try "{}\n".write(to: da3ConfigFile, atomically: true, encoding: .utf8)
            try #"{"repo_id":"depth-anything/DA3-BASE","resolved_sha":"fixture","license":"apache-2.0"}"#.write(to: da3ModelInfoFile, atomically: true, encoding: .utf8)
        }
        if includeDa3FallbackModel {
            fm.createFile(atPath: da3FallbackModelFile.path, contents: Data([0x00]))
            try "{}\n".write(to: da3FallbackConfigFile, atomically: true, encoding: .utf8)
            try #"{"repo_id":"depth-anything/DA3-SMALL","resolved_sha":"fixture","license":"apache-2.0"}"#.write(to: da3FallbackModelInfoFile, atomically: true, encoding: .utf8)
        }
        if includeDa3VendorSentinel {
            fm.createFile(atPath: da3VendorSentinel.path, contents: Data([0x00]))
        }

        let mapanythingRoot = root.appendingPathComponent("mapanything_mps", isDirectory: true)
        let mapanythingSfmTool = mapanythingRoot.appendingPathComponent("bin/easysplat_mapanything_sfm")
        let mapanythingPython = mapanythingRoot.appendingPathComponent("python/bin/python3")
        let mapanythingBuildInfo = mapanythingRoot.appendingPathComponent("build_info.json")
        let mapanythingAppSentinel = mapanythingRoot.appendingPathComponent("app/easysplat_mapanything_sfm/run.py")
        let mapanythingModels = mapanythingRoot.appendingPathComponent("models", isDirectory: true)
        let mapanythingModelBundle = mapanythingModels.appendingPathComponent("map-anything-apache", isDirectory: true)
        let mapanythingModelFile = mapanythingModelBundle.appendingPathComponent("model.safetensors")
        let mapanythingConfigFile = mapanythingModelBundle.appendingPathComponent("config.json")
        let mapanythingDinov2Weights = mapanythingModels.appendingPathComponent("dinov2/dinov2_vitg14_pretrain.pth")
        let mapanythingVendorSentinel = mapanythingRoot.appendingPathComponent("vendor/mapanything/mapanything/models/mapanything/model.py")

        try fm.createDirectory(at: mapanythingSfmTool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: mapanythingPython.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: mapanythingAppSentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: mapanythingModelBundle, withIntermediateDirectories: true)
        try fm.createDirectory(at: mapanythingDinov2Weights.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: mapanythingVendorSentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeExecutable(mapanythingSfmTool, script: "#!/usr/bin/env bash\nexit 0\n")
        try writeExecutable(mapanythingPython, script: "#!/usr/bin/env bash\necho python\n")
        try """
        {
          "toolchain_name": "mapanything_mps",
          "source_path": "fixture",
          "python_version": "3.13.11",
          "torch_version": "2.10.0",
          "torchvision_version": "0.25.0"
        }
        """.write(to: mapanythingBuildInfo, atomically: true, encoding: .utf8)
        if includeMapAnythingAppSentinel {
            try "from __future__ import annotations\n".write(to: mapanythingAppSentinel, atomically: true, encoding: .utf8)
        }
        if includeMapAnythingModel {
            fm.createFile(atPath: mapanythingModelFile.path, contents: Data([0x00]))
            try "{}\n".write(to: mapanythingConfigFile, atomically: true, encoding: .utf8)
            fm.createFile(atPath: mapanythingDinov2Weights.path, contents: Data([0x00]))
        }
        if includeMapAnythingVendorSentinel {
            fm.createFile(atPath: mapanythingVendorSentinel.path, contents: Data([0x00]))
        }

        let vggtRoot = root.appendingPathComponent("vggt_mps", isDirectory: true)
        let vggtSfmTool = vggtRoot.appendingPathComponent("bin/easysplat_vggt_sfm")
        let vggtPython = vggtRoot.appendingPathComponent("python/bin/python3")
        let vggtBuildInfo = vggtRoot.appendingPathComponent("build_info.json")
        let vggtAppSentinel = vggtRoot.appendingPathComponent("app/easysplat_vggt_sfm/run.py")
        let vggtModels = vggtRoot.appendingPathComponent("models", isDirectory: true)
        let vggtModelFile = vggtModels.appendingPathComponent("vggt_model.pt")
        let vggtVendorSentinel = vggtRoot.appendingPathComponent("vendor/vggt/vggt/models/vggt.py")

        try fm.createDirectory(at: vggtSfmTool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: vggtPython.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: vggtAppSentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: vggtModels, withIntermediateDirectories: true)
        try fm.createDirectory(at: vggtVendorSentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeExecutable(vggtSfmTool, script: "#!/usr/bin/env bash\nexit 0\n")
        try writeExecutable(vggtPython, script: "#!/usr/bin/env bash\necho python\n")
        if includeVggtBuildInfo {
            try """
            {
              "toolchain_name": "vggt_mps",
              "source_path": "fixture",
              "python_version": "3.13.11",
              "torch_version": "2.10.0",
              "torchvision_version": "0.25.0"
            }
            """.write(to: vggtBuildInfo, atomically: true, encoding: .utf8)
        }
        if includeVggtAppSentinel {
            try "from __future__ import annotations\n".write(to: vggtAppSentinel, atomically: true, encoding: .utf8)
        }
        if includeVggtModel {
            fm.createFile(atPath: vggtModelFile.path, contents: Data([0x00]))
        }
        if includeVendorSentinel {
            fm.createFile(atPath: vggtVendorSentinel.path, contents: Data([0x00]))
        }

        let fastvggtRoot = root.appendingPathComponent("fastvggt_mps", isDirectory: true)
        let fastvggtSfmTool = fastvggtRoot.appendingPathComponent("bin/easysplat_fastvggt_sfm")
        let fastvggtPython = fastvggtRoot.appendingPathComponent("python/bin/python3")
        let fastvggtBuildInfo = fastvggtRoot.appendingPathComponent("build_info.json")
        let fastvggtAppSentinel = fastvggtRoot.appendingPathComponent("app/easysplat_fastvggt_sfm/run.py")
        let fastvggtModels = fastvggtRoot.appendingPathComponent("models", isDirectory: true)
        let fastvggtModelFile = fastvggtModels.appendingPathComponent("fastvggt_model.pt")
        let fastvggtVendorSentinel = fastvggtRoot.appendingPathComponent("vendor/fastvggt/vggt/models/vggt.py")

        try fm.createDirectory(at: fastvggtSfmTool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: fastvggtPython.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: fastvggtAppSentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: fastvggtModels, withIntermediateDirectories: true)
        try fm.createDirectory(at: fastvggtVendorSentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeExecutable(fastvggtSfmTool, script: "#!/usr/bin/env bash\nexit 0\n")
        try writeExecutable(fastvggtPython, script: "#!/usr/bin/env bash\necho python\n")
        if includeFastVggtBuildInfo {
            try """
            {
              "toolchain_name": "fastvggt_mps",
              "source_path": "fixture",
              "python_version": "3.13.11",
              "torch_version": "2.10.0",
              "torchvision_version": "0.25.0"
            }
            """.write(to: fastvggtBuildInfo, atomically: true, encoding: .utf8)
        }
        if includeFastVggtAppSentinel {
            try "from __future__ import annotations\n".write(to: fastvggtAppSentinel, atomically: true, encoding: .utf8)
        }
        if includeFastVggtModel {
            fm.createFile(atPath: fastvggtModelFile.path, contents: Data([0x00]))
        }
        if includeFastVggtVendorSentinel {
            fm.createFile(atPath: fastvggtVendorSentinel.path, contents: Data([0x00]))
        }

        return ToolchainFixture(
            root: root,
            colmap: colmap,
            glomap: glomap,
            brush: brush,
            brushReal: brushReal,
            libcrypto: libcrypto,
            libssl: libssl,
            da3Root: da3Root,
            da3SfmTool: da3SfmTool,
            da3Python: da3Python,
            da3BuildInfo: da3BuildInfo,
            da3AppSentinel: da3AppSentinel,
            da3Models: da3Models,
            da3ModelBundle: da3ModelBundle,
            da3ModelFile: da3ModelFile,
            da3ConfigFile: da3ConfigFile,
            da3FallbackModelBundle: da3FallbackModelBundle,
            da3FallbackModelFile: da3FallbackModelFile,
            da3FallbackConfigFile: da3FallbackConfigFile,
            da3VendorSentinel: da3VendorSentinel,
            mapanythingRoot: mapanythingRoot,
            mapanythingSfmTool: mapanythingSfmTool,
            mapanythingPython: mapanythingPython,
            mapanythingBuildInfo: mapanythingBuildInfo,
            mapanythingAppSentinel: mapanythingAppSentinel,
            mapanythingModels: mapanythingModels,
            mapanythingModelBundle: mapanythingModelBundle,
            mapanythingModelFile: mapanythingModelFile,
            mapanythingConfigFile: mapanythingConfigFile,
            mapanythingDinov2Weights: mapanythingDinov2Weights,
            mapanythingVendorSentinel: mapanythingVendorSentinel,
            vggtRoot: vggtRoot,
            vggtSfmTool: vggtSfmTool,
            vggtPython: vggtPython,
            vggtBuildInfo: vggtBuildInfo,
            vggtAppSentinel: vggtAppSentinel,
            vggtModels: vggtModels,
            vggtModelFile: vggtModelFile,
            vggtVendorSentinel: vggtVendorSentinel,
            fastvggtRoot: fastvggtRoot,
            fastvggtSfmTool: fastvggtSfmTool,
            fastvggtPython: fastvggtPython,
            fastvggtBuildInfo: fastvggtBuildInfo,
            fastvggtAppSentinel: fastvggtAppSentinel,
            fastvggtModels: fastvggtModels,
            fastvggtModelFile: fastvggtModelFile,
            fastvggtVendorSentinel: fastvggtVendorSentinel
        )
    }

    static func makeToolchainPaths(from fixture: ToolchainFixture) -> ToolchainPaths {
        let da3 = Da3Toolchain(
            root: fixture.da3Root,
            sfmTool: fixture.da3SfmTool,
            python: fixture.da3Python,
            models: fixture.da3Models,
            modelBundle: fixture.da3ModelBundle,
            fallbackModelBundle: fixture.da3FallbackModelBundle
        )
        let mapanything = MapAnythingToolchain(
            root: fixture.mapanythingRoot,
            sfmTool: fixture.mapanythingSfmTool,
            python: fixture.mapanythingPython,
            models: fixture.mapanythingModels,
            modelBundle: fixture.mapanythingModelBundle,
            dinov2Weights: fixture.mapanythingDinov2Weights
        )
        let vggt = VggtToolchain(
            root: fixture.vggtRoot,
            sfmTool: fixture.vggtSfmTool,
            python: fixture.vggtPython,
            models: fixture.vggtModels
        )
        let fastvggt = FastVggtToolchain(
            root: fixture.fastvggtRoot,
            sfmTool: fixture.fastvggtSfmTool,
            python: fixture.fastvggtPython,
            models: fixture.fastvggtModels
        )
        return ToolchainPaths(
            root: fixture.root,
            colmap: fixture.colmap,
            glomap: fixture.glomap,
            brush: fixture.brush,
            da3: da3,
            mapanything: mapanything,
            vggt: vggt,
            fastvggt: fastvggt
        )
    }
}
