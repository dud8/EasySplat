import CryptoKit
import Foundation
@testable import EasySplatCore

struct ToolchainFixture {
    let root: URL
    let colmap: URL
    let da3Root: URL
    let da3SfmTool: URL
    let da3Python: URL
    let da3BuildInfo: URL
    let da3AppSentinel: URL
    let da3Models: URL
    let da3ModelBundle: URL
    let da3ModelFile: URL
    let da3ConfigFile: URL
    let da3SmallModelBundle: URL
    let da3SmallModelFile: URL
    let da3SmallConfigFile: URL
    let da3VendorSentinel: URL
}

enum ToolchainFixtureBuilder {
    static func createToolchain(
        at root: URL,
        includeDa3Model: Bool = true,
        includeDa3SmallModel: Bool = true,
        includeDa3AppSentinel: Bool = true,
        includeDa3VendorSentinel: Bool = true,
        includeMsplat: Bool = true
    ) throws -> ToolchainFixture {
        let fm = FileManager.default
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        let supplyChain = root.appendingPathComponent("supply-chain", isDirectory: true)
        try fm.createDirectory(at: supplyChain, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: supplyChain.appendingPathComponent("components.json"))

        func writeExecutable(_ url: URL, script: String?) throws {
            if let script {
                try script.write(to: url, atomically: true, encoding: .utf8)
            } else {
                fm.createFile(atPath: url.path, contents: Data())
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        let colmap = bin.appendingPathComponent("colmap")
        try writeExecutable(colmap, script: "#!/usr/bin/env bash\nexit 0\n")
        let colmapProvenance = root.appendingPathComponent("provenance/colmap.json")
        try fm.createDirectory(
            at: colmapProvenance.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let colmapExecutableSHA256 = SHA256.hash(data: try Data(contentsOf: colmap))
            .map { String(format: "%02x", $0) }
            .joined()
        try """
        {
          "toolchain_name": "colmap",
          "source_version": "4.1.1",
          "source_commit": "a0d785fba74b2664f31edc4a29026a8b27c00f67",
          "executable_sha256": "\(colmapExecutableSHA256)"
        }
        """.write(to: colmapProvenance, atomically: true, encoding: .utf8)

        let coreSupportFiles: [String: String] = [
            "lib/libomp.dylib": "fixture OpenMP runtime\n",
            "provenance/colmap-support.json": "{}\n",
            "provenance/ceres.json": "{}\n",
            "provenance/openimageio.json": "{}\n",
            "licenses/COLMAP/COPYING.txt": "BSD-3-Clause\n",
            "licenses/COLMAPSupport/OpenMP-LICENSE.txt": "Apache-2.0 WITH LLVM-exception\n",
            "licenses/Ceres/LICENSE": "BSD-3-Clause\n",
            "licenses/OpenImageIO/LICENSE.md": "BSD-3-Clause\n",
        ]
        for (relativePath, contents) in coreSupportFiles {
            let url = root.appendingPathComponent(relativePath)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }


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
                "overlay_sha256": "975b515aa10c8aca854e0cd3a638cb71e3b6e51aed156410242bae9af0e295e1",
                "raster_test_sha256": "06eec969719a4b44102280eed79d817c8774dafbd3050b90324d9898bc57e43d",
                "isolation_header_sha256": "267442c64a2eabe21662fd0c51dfa7bddeb2afaefdc58bc69d115699f1b6aa5f",
                "isolation_source_sha256": "a13a277555e94861e78d04c127729a6a30b0204e4db60b3b3de743a7009de751",
                "isolation_runtime_header_sha256": "192cbccaa5ab6b87a533ff27bca720a0512ffda5182a6e35080584d2091477b8",
                "isolation_runtime_source_sha256": "0c77172b7ac5f0f314fc0907cc4d86bca01fd62756f52b477e435da520c984fa",
                "isolation_mask_header_sha256": "51956923935621ef2e3681f33e11b1f63a6d1ed969234ee9e50edab927f712d7",
                "isolation_mask_source_sha256": "ad9844c13dd427517311f0ad0725ffa348beb4c590d6febc6efe11c38d7240e8",
                "isolation_lift_source_sha256": "c063a934eee67eb22e04483f32e798e6844ee722dde9daddeed79f5db56c13bc",
                "isolation_test_sha256": "f2f58c26d52178ee5324e51fe3486501d7ad3e78d8e8c06ac4da1060ef937e54",
                "isolation_mask_test_sha256": "f4900f77878a22417c1bd397ee87d2730c21344d9ba9ab7e1579bfa083e7d2bc",
                "isolation_patch_sha256": "a8a579d9d2a5ca23ce87ae0dd2a1f79de8da56bbfa62851244cfdda51bc37f59",
                "patch_sha256": "047ef2547d4478bc77a7a1537284e58fdb20de4c52c5c37982674fa2af70927e",
                "source_notice_patch_sha256": "6deee598c9321c9b98d74b92fd5cce9808069a7a63effcd80615eb7d208d2ffb",
                "checkpoint_patch_sha256": String(repeating: "d", count: 64),
                "numeric_stability_patch_sha256": String(repeating: "e", count: 64),
                "metal_safety_patch_sha256": String(repeating: "f", count: 64),
                "exact_raster_patch_sha256": "c34a8860ed8ae9bc92c976aaa1c3f89eec8aa9be9cab4778f074491e98860855",
                "stage_timing_patch_sha256": "fcc00c8b9eb3c79ccc7be3f27b997421b28e2c0ea98477c4382d7acefd334435",
                "memory_efficiency_patch_sha256": "bfacc105454e80102139f120dd6375037360c6a9763f1e1f708aa2a7f22eca6c",
                "densification_memory_patch_sha256": "b429540372d807f280929ebba1670257990bd36b28dfee5b42bc377ccef60ac7",
                "row_span_culling_patch_sha256": "481c4c9a70f1da5eb1590b20a64e25a3c64bb3c19f14e27996ab9b25a119594d",
                "geometry_adam_fusion_patch_sha256": "927ad1fdbffee7ad762396c7acc965cd4a20da781f172240c62aa94f41e1cd2c",
                "parallel_radix_scan_patch_sha256": "1caedde675063dd0b119e91ec39a6945328ecf37134a83b079dce964a7a816c4",
                "allocation_pressure_patch_sha256": "34611e91e896f56c9ad81ae2c4bd55352b4172d5cbdb83da7658e9050382b4a8",
                "exact_prefix_hardening_patch_sha256": "510d70ac3413cbf1260881ed1399e5301cc1fce0d783a1e451381c9e3ec8c9fb",
                "quaternion_stability_patch_sha256": "d0aabc26d10b316a669c120ebdfdf573dd645c30c857e97b6ceeaa8c2c76b786",
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
                    "-DMSPLAT_BUILD_RASTER_TESTS=ON",
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
        let da3SmallModelBundle = da3Models.appendingPathComponent("DA3-SMALL", isDirectory: true)
        let da3SmallModelFile = da3SmallModelBundle.appendingPathComponent("model.safetensors")
        let da3SmallConfigFile = da3SmallModelBundle.appendingPathComponent("config.json")
        let da3SmallModelInfoFile = da3SmallModelBundle.appendingPathComponent("easysplat_model_info.json")
        let da3VendorSentinel = da3Root.appendingPathComponent("vendor/depth-anything-3/src/depth_anything_3/api.py")

        try fm.createDirectory(at: da3SfmTool.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: da3Python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: da3AppSentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: da3ModelBundle, withIntermediateDirectories: true)
        try fm.createDirectory(at: da3SmallModelBundle, withIntermediateDirectories: true)
        try fm.createDirectory(at: da3VendorSentinel.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeExecutable(da3SfmTool, script: "#!/usr/bin/env bash\nexit 0\n")
        try writeExecutable(da3Python, script: "#!/usr/bin/env bash\necho python\n")
        try """
        {
          "toolchain_name": "da3_mps",
          "source_repo": "https://github.com/ByteDance-Seed/Depth-Anything-3.git",
          "source_ref": "test-fixture",
          "source_commit": "a0b8a92e3d1532361c2f7feb63babc5c18d00ef2",
          "source_path": "fixture",
          "base_checkpoint_commit": "0123456789abcdef0123456789abcdef01234567",
          "small_checkpoint_commit": "89abcdef0123456789abcdef0123456789abcdef",
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
            try #"{"repo_id":"depth-anything/DA3-BASE","requested_revision":"fixture-revision","resolved_sha":"0123456789abcdef0123456789abcdef01234567","license":"apache-2.0"}"#.write(to: da3ModelInfoFile, atomically: true, encoding: .utf8)
            try "Apache License 2.0\n".write(
                to: da3ModelBundle.appendingPathComponent("LICENSE"),
                atomically: true,
                encoding: .utf8
            )
        }
        if includeDa3SmallModel {
            fm.createFile(atPath: da3SmallModelFile.path, contents: Data([0x00]))
            try "{}\n".write(to: da3SmallConfigFile, atomically: true, encoding: .utf8)
            try #"{"repo_id":"depth-anything/DA3-SMALL","requested_revision":"fixture-revision","resolved_sha":"89abcdef0123456789abcdef0123456789abcdef","license":"apache-2.0"}"#.write(to: da3SmallModelInfoFile, atomically: true, encoding: .utf8)
            try "Apache License 2.0\n".write(
                to: da3SmallModelBundle.appendingPathComponent("LICENSE"),
                atomically: true,
                encoding: .utf8
            )
        }
        if includeDa3VendorSentinel {
            fm.createFile(atPath: da3VendorSentinel.path, contents: Data([0x00]))
        }

        return ToolchainFixture(
            root: root,
            colmap: colmap,
            da3Root: da3Root,
            da3SfmTool: da3SfmTool,
            da3Python: da3Python,
            da3BuildInfo: da3BuildInfo,
            da3AppSentinel: da3AppSentinel,
            da3Models: da3Models,
            da3ModelBundle: da3ModelBundle,
            da3ModelFile: da3ModelFile,
            da3ConfigFile: da3ConfigFile,
            da3SmallModelBundle: da3SmallModelBundle,
            da3SmallModelFile: da3SmallModelFile,
            da3SmallConfigFile: da3SmallConfigFile,
            da3VendorSentinel: da3VendorSentinel
        )
    }

    static func makeToolchainPaths(from fixture: ToolchainFixture) -> ToolchainPaths {
        let da3 = Da3Toolchain(
            root: fixture.da3Root,
            sfmTool: fixture.da3SfmTool,
            python: fixture.da3Python,
            models: fixture.da3Models,
            modelBundle: fixture.da3ModelBundle,
            smallModelBundle: fixture.da3SmallModelBundle
        )
        return ToolchainPaths(
            root: fixture.root,
            colmap: fixture.colmap,
            msplat: fixture.root.appendingPathComponent("bin/easysplat-train"),
            da3: da3
        )
    }
}
