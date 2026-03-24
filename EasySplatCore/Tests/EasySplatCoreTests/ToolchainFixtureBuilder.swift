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
        includeFastVggtVendorSentinel: Bool = true
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
            mapanything: mapanything,
            vggt: vggt,
            fastvggt: fastvggt
        )
    }
}
