import Foundation

extension ToolchainManager {
    func validateToolchain(root: URL) throws -> ToolchainPaths {
        let colmap = root.appendingPathComponent("bin/colmap")
        let brush = root.appendingPathComponent("bin/brush")
        let brushReal = root.appendingPathComponent("bin/brush.real")
        ensureExecutable(at: colmap)
        ensureExecutable(at: brush)
        guard fileManager.isExecutableFile(atPath: colmap.path) else { throw ToolchainError.missingBinary("colmap") }
        guard fileManager.isExecutableFile(atPath: brush.path) else { throw ToolchainError.missingBinary("brush") }
        if fileHasShebang(at: brush) {
            ensureExecutable(at: brushReal)
            guard fileManager.isExecutableFile(atPath: brushReal.path) else { throw ToolchainError.missingBinary("brush.real") }
        }

        let libcrypto = root.appendingPathComponent("lib/libcrypto.3.dylib")
        let libssl = root.appendingPathComponent("lib/libssl.3.dylib")
        guard fileManager.fileExists(atPath: libcrypto.path) else { throw ToolchainError.missingLibrary("libcrypto.3.dylib") }
        guard fileManager.fileExists(atPath: libssl.path) else { throw ToolchainError.missingLibrary("libssl.3.dylib") }

        try requireArm64Binary(at: colmap, label: "colmap")
        // brush itself may be a shebang-wrapped launcher; arch-check the real binary in that case.
        let brushBinary = fileHasShebang(at: brush) ? brushReal : brush
        try requireArm64Binary(at: brushBinary, label: "brush")

        let colmapCheck = try runner.run(colmap.path, ["-h"])
        guard colmapCheck.exitCode == 0 else {
            throw ToolchainError.invalidToolchain("COLMAP failed to launch (exit \(colmapCheck.exitCode)).")
        }

        if let globalMapperProbe = try? runner.run(colmap.path, ["global_mapper"]),
           globalMapperProbe.exitCode != 0 {
            let text = "\(globalMapperProbe.stdout)\n\(globalMapperProbe.stderr)".lowercased()
            if text.contains("library not loaded") || text.contains("no lc_rpath") || text.contains("@rpath/libcrypto.3.dylib") {
                throw ToolchainError.invalidToolchain("COLMAP global_mapper failed to launch (missing dylib/rpath).")
            }
        }

        let brushCheck = try runner.run(brush.path, ["--help"])
        guard brushCheck.exitCode == 0 else {
            throw ToolchainError.invalidToolchain("Brush failed to launch (exit \(brushCheck.exitCode)).")
        }

        let da3Root = root.appendingPathComponent("da3_mps", isDirectory: true)
        let da3SfmTool = da3Root.appendingPathComponent("bin/easysplat_da3_sfm")
        let da3Python = da3Root.appendingPathComponent("python/bin/python3")
        let da3BuildInfo = da3Root.appendingPathComponent("build_info.json")
        let da3AppSentinel = da3Root.appendingPathComponent("app/easysplat_da3_sfm/run.py")
        let da3Models = da3Root.appendingPathComponent("models", isDirectory: true)
        let da3ModelBundle = da3Models.appendingPathComponent("DA3-BASE", isDirectory: true)
        let da3FallbackModelBundle = da3Models.appendingPathComponent("DA3-SMALL", isDirectory: true)
        let da3BaseModelFile = da3ModelBundle.appendingPathComponent("model.safetensors")
        let da3BaseConfigFile = da3ModelBundle.appendingPathComponent("config.json")
        let da3BaseModelInfoFile = da3ModelBundle.appendingPathComponent("easysplat_model_info.json")
        let da3SmallModelFile = da3FallbackModelBundle.appendingPathComponent("model.safetensors")
        let da3SmallConfigFile = da3FallbackModelBundle.appendingPathComponent("config.json")
        let da3SmallModelInfoFile = da3FallbackModelBundle.appendingPathComponent("easysplat_model_info.json")
        let da3VendorSentinel = da3Root.appendingPathComponent("vendor/depth-anything-3/src/depth_anything_3/api.py")

        if shouldRequireDa3ForToolchainValidation() {
            guard fileManager.fileExists(atPath: da3SfmTool.path) else {
                throw ToolchainError.missingBinary("da3_mps/bin/easysplat_da3_sfm")
            }
            guard fileManager.fileExists(atPath: da3Python.path) else {
                throw ToolchainError.missingBinary("da3_mps/python/bin/python3")
            }
            guard fileManager.fileExists(atPath: da3BuildInfo.path) else {
                throw ToolchainError.missingLibrary("da3_mps/build_info.json")
            }
            guard fileManager.fileExists(atPath: da3AppSentinel.path) else {
                throw ToolchainError.missingLibrary("da3_mps/app/easysplat_da3_sfm/run.py")
            }
            guard fileManager.fileExists(atPath: da3Models.path) else {
                throw ToolchainError.missingLibrary("da3_mps/models")
            }
            guard fileManager.fileExists(atPath: da3BaseModelFile.path) else {
                throw ToolchainError.missingLibrary("da3_mps/models/DA3-BASE/model.safetensors")
            }
            guard fileManager.fileExists(atPath: da3BaseConfigFile.path) else {
                throw ToolchainError.missingLibrary("da3_mps/models/DA3-BASE/config.json")
            }
            guard fileManager.fileExists(atPath: da3BaseModelInfoFile.path) else {
                throw ToolchainError.missingLibrary("da3_mps/models/DA3-BASE/easysplat_model_info.json")
            }
            guard fileManager.fileExists(atPath: da3SmallModelFile.path) else {
                throw ToolchainError.missingLibrary("da3_mps/models/DA3-SMALL/model.safetensors")
            }
            guard fileManager.fileExists(atPath: da3SmallConfigFile.path) else {
                throw ToolchainError.missingLibrary("da3_mps/models/DA3-SMALL/config.json")
            }
            guard fileManager.fileExists(atPath: da3SmallModelInfoFile.path) else {
                throw ToolchainError.missingLibrary("da3_mps/models/DA3-SMALL/easysplat_model_info.json")
            }
            guard fileManager.fileExists(atPath: da3VendorSentinel.path) else {
                throw ToolchainError.missingLibrary("da3_mps/vendor/depth-anything-3")
            }

            ensureExecutable(at: da3SfmTool)
            ensureExecutable(at: da3Python)
            try validateBuildInfo(at: da3BuildInfo, expectedToolchainName: "da3_mps")

            try requireArm64Binary(at: da3Python, label: "da3_mps python")
            let da3Check = try runner.run(da3SfmTool.path, ["--help"])
            guard da3Check.exitCode == 0 else {
                throw ToolchainError.invalidToolchain("da3_mps failed to launch (exit \(da3Check.exitCode)).")
            }
        }

        let da3 = Da3Toolchain(
            root: da3Root,
            sfmTool: da3SfmTool,
            python: da3Python,
            models: da3Models,
            modelBundle: da3ModelBundle,
            fallbackModelBundle: da3FallbackModelBundle
        )

        let mapAnythingRoot = root.appendingPathComponent("mapanything_mps", isDirectory: true)
        let mapAnythingSfmTool = mapAnythingRoot.appendingPathComponent("bin/easysplat_mapanything_sfm")
        let mapAnythingPython = mapAnythingRoot.appendingPathComponent("python/bin/python3")
        let mapAnythingBuildInfo = mapAnythingRoot.appendingPathComponent("build_info.json")
        let mapAnythingModels = mapAnythingRoot.appendingPathComponent("models", isDirectory: true)
        let mapAnythingModelBundle = mapAnythingModels.appendingPathComponent("map-anything-apache", isDirectory: true)
        let mapAnythingModelFile = mapAnythingModelBundle.appendingPathComponent("model.safetensors")
        let mapAnythingConfigFile = mapAnythingModelBundle.appendingPathComponent("config.json")
        let mapAnythingDinov2Weights = mapAnythingModels.appendingPathComponent("dinov2/dinov2_vitg14_pretrain.pth")
        let mapAnythingAppSentinel = mapAnythingRoot.appendingPathComponent("app/easysplat_mapanything_sfm/run.py")
        let mapAnythingVendorSentinel = mapAnythingRoot.appendingPathComponent("vendor/mapanything/mapanything/models/mapanything/model.py")

        guard fileManager.fileExists(atPath: mapAnythingSfmTool.path) else {
            throw ToolchainError.missingBinary("mapanything_mps/bin/easysplat_mapanything_sfm")
        }
        guard fileManager.fileExists(atPath: mapAnythingPython.path) else {
            throw ToolchainError.missingBinary("mapanything_mps/python/bin/python3")
        }
        guard fileManager.fileExists(atPath: mapAnythingBuildInfo.path) else {
            throw ToolchainError.missingLibrary("mapanything_mps/build_info.json")
        }
        guard fileManager.fileExists(atPath: mapAnythingAppSentinel.path) else {
            throw ToolchainError.missingLibrary("mapanything_mps/app/easysplat_mapanything_sfm/run.py")
        }
        guard fileManager.fileExists(atPath: mapAnythingModels.path) else {
            throw ToolchainError.missingLibrary("mapanything_mps/models")
        }
        guard fileManager.fileExists(atPath: mapAnythingModelFile.path) else {
            throw ToolchainError.missingLibrary("mapanything_mps/models/map-anything-apache/model.safetensors")
        }
        guard fileManager.fileExists(atPath: mapAnythingConfigFile.path) else {
            throw ToolchainError.missingLibrary("mapanything_mps/models/map-anything-apache/config.json")
        }
        guard fileManager.fileExists(atPath: mapAnythingDinov2Weights.path) else {
            throw ToolchainError.missingLibrary("mapanything_mps/models/dinov2/dinov2_vitg14_pretrain.pth")
        }
        guard fileManager.fileExists(atPath: mapAnythingVendorSentinel.path) else {
            throw ToolchainError.missingLibrary("mapanything_mps/vendor/mapanything")
        }

        ensureExecutable(at: mapAnythingSfmTool)
        ensureExecutable(at: mapAnythingPython)
        try validateBuildInfo(at: mapAnythingBuildInfo, expectedToolchainName: "mapanything_mps")

        try requireArm64Binary(at: mapAnythingPython, label: "mapanything_mps python")
        let mapAnythingCheck = try runner.run(mapAnythingSfmTool.path, ["--help"])
        guard mapAnythingCheck.exitCode == 0 else {
            throw ToolchainError.invalidToolchain("mapanything_mps failed to launch (exit \(mapAnythingCheck.exitCode)).")
        }

        let mapanything = MapAnythingToolchain(
            root: mapAnythingRoot,
            sfmTool: mapAnythingSfmTool,
            python: mapAnythingPython,
            models: mapAnythingModels,
            modelBundle: mapAnythingModelBundle,
            dinov2Weights: mapAnythingDinov2Weights
        )

        let vggtRoot = root.appendingPathComponent("vggt_mps", isDirectory: true)
        let vggtSfmTool = vggtRoot.appendingPathComponent("bin/easysplat_vggt_sfm")
        let vggtPython = vggtRoot.appendingPathComponent("python/bin/python3")
        let vggtBuildInfo = vggtRoot.appendingPathComponent("build_info.json")
        let vggtAppSentinel = vggtRoot.appendingPathComponent("app/easysplat_vggt_sfm/run.py")
        let vggtModels = vggtRoot.appendingPathComponent("models", isDirectory: true)
        let vggtModelFile = vggtModels.appendingPathComponent("vggt_model.pt")
        let vggtVendorSentinel = vggtRoot.appendingPathComponent("vendor/vggt/vggt/models/vggt.py")

        guard fileManager.fileExists(atPath: vggtSfmTool.path) else {
            throw ToolchainError.missingBinary("vggt_mps/bin/easysplat_vggt_sfm")
        }
        guard fileManager.fileExists(atPath: vggtPython.path) else {
            throw ToolchainError.missingBinary("vggt_mps/python/bin/python3")
        }
        guard fileManager.fileExists(atPath: vggtBuildInfo.path) else {
            throw ToolchainError.missingLibrary("vggt_mps/build_info.json")
        }
        guard fileManager.fileExists(atPath: vggtAppSentinel.path) else {
            throw ToolchainError.missingLibrary("vggt_mps/app/easysplat_vggt_sfm/run.py")
        }
        guard fileManager.fileExists(atPath: vggtModels.path) else {
            throw ToolchainError.missingLibrary("vggt_mps/models")
        }
        guard fileManager.fileExists(atPath: vggtModelFile.path) else {
            throw ToolchainError.missingLibrary("vggt_mps/models/vggt_model.pt")
        }
        guard fileManager.fileExists(atPath: vggtVendorSentinel.path) else {
            throw ToolchainError.missingLibrary("vggt_mps/vendor/vggt")
        }

        ensureExecutable(at: vggtSfmTool)
        ensureExecutable(at: vggtPython)
        try validateBuildInfo(at: vggtBuildInfo, expectedToolchainName: "vggt_mps")

        try requireArm64Binary(at: vggtPython, label: "vggt_mps python")
        let vggtCheck = try runner.run(vggtSfmTool.path, ["--help"])
        guard vggtCheck.exitCode == 0 else {
            throw ToolchainError.invalidToolchain("vggt_mps failed to launch (exit \(vggtCheck.exitCode)).")
        }

        let vggt = VggtToolchain(
            root: vggtRoot,
            sfmTool: vggtSfmTool,
            python: vggtPython,
            models: vggtModels
        )

        let fastvggtRoot = root.appendingPathComponent("fastvggt_mps", isDirectory: true)
        let fastvggtSfmTool = fastvggtRoot.appendingPathComponent("bin/easysplat_fastvggt_sfm")
        let fastvggtPython = fastvggtRoot.appendingPathComponent("python/bin/python3")
        let fastvggtBuildInfo = fastvggtRoot.appendingPathComponent("build_info.json")
        let fastvggtAppSentinel = fastvggtRoot.appendingPathComponent("app/easysplat_fastvggt_sfm/run.py")
        let fastvggtModels = fastvggtRoot.appendingPathComponent("models", isDirectory: true)
        let fastvggtModelFile = fastvggtModels.appendingPathComponent("fastvggt_model.pt")
        let fastvggtVendorSentinel = fastvggtRoot.appendingPathComponent("vendor/fastvggt/vggt/models/vggt.py")

        guard fileManager.fileExists(atPath: fastvggtSfmTool.path) else {
            throw ToolchainError.missingBinary("fastvggt_mps/bin/easysplat_fastvggt_sfm")
        }
        guard fileManager.fileExists(atPath: fastvggtPython.path) else {
            throw ToolchainError.missingBinary("fastvggt_mps/python/bin/python3")
        }
        guard fileManager.fileExists(atPath: fastvggtBuildInfo.path) else {
            throw ToolchainError.missingLibrary("fastvggt_mps/build_info.json")
        }
        guard fileManager.fileExists(atPath: fastvggtAppSentinel.path) else {
            throw ToolchainError.missingLibrary("fastvggt_mps/app/easysplat_fastvggt_sfm/run.py")
        }
        guard fileManager.fileExists(atPath: fastvggtModels.path) else {
            throw ToolchainError.missingLibrary("fastvggt_mps/models")
        }
        guard fileManager.fileExists(atPath: fastvggtModelFile.path) else {
            throw ToolchainError.missingLibrary("fastvggt_mps/models/fastvggt_model.pt")
        }
        guard fileManager.fileExists(atPath: fastvggtVendorSentinel.path) else {
            throw ToolchainError.missingLibrary("fastvggt_mps/vendor/fastvggt")
        }

        ensureExecutable(at: fastvggtSfmTool)
        ensureExecutable(at: fastvggtPython)
        try validateBuildInfo(at: fastvggtBuildInfo, expectedToolchainName: "fastvggt_mps")

        try requireArm64Binary(at: fastvggtPython, label: "fastvggt_mps python")
        let fastvggtCheck = try runner.run(fastvggtSfmTool.path, ["--help"])
        guard fastvggtCheck.exitCode == 0 else {
            throw ToolchainError.invalidToolchain("fastvggt_mps failed to launch (exit \(fastvggtCheck.exitCode)).")
        }

        let fastvggt = FastVggtToolchain(
            root: fastvggtRoot,
            sfmTool: fastvggtSfmTool,
            python: fastvggtPython,
            models: fastvggtModels
        )

        let msplat = root.appendingPathComponent("bin/easysplat-train")
        let msplatMetallib = root.appendingPathComponent("bin/default.metallib")
        let msplatRoot = root.appendingPathComponent("msplat", isDirectory: true)
        let msplatBuildInfo = msplatRoot.appendingPathComponent("build_info.json")
        let msplatLicense = msplatRoot.appendingPathComponent("LICENSE")
        try rejectLegacyMsplatFootprint(root: root)
        let msplatEntries = [msplat, msplatMetallib, msplatRoot, msplatBuildInfo, msplatLicense]
        let hasMsplatBundle = msplatEntries.contains { pathExistsIncludingSymlink($0) }
        if hasMsplatBundle {
            guard pathExistsIncludingSymlink(msplat) else {
                throw ToolchainError.missingBinary("bin/easysplat-train")
            }
            guard pathExistsIncludingSymlink(msplatMetallib) else {
                throw ToolchainError.missingLibrary("bin/default.metallib")
            }
            guard pathExistsIncludingSymlink(msplatBuildInfo) else {
                throw ToolchainError.missingLibrary("msplat/build_info.json")
            }
            guard pathExistsIncludingSymlink(msplatLicense) else {
                throw ToolchainError.missingLibrary("msplat/LICENSE")
            }

            let runtimeVersion = try validateNativeMsplatClosure(
                root: root,
                executable: msplat,
                metallib: msplatMetallib,
                buildInfo: msplatBuildInfo,
                license: msplatLicense
            )
            ensureExecutable(at: msplat)
            try requireArm64Binary(at: msplat, label: "easysplat-train")
            try validateMsplatSelfCheck(executable: msplat, runtimeVersion: runtimeVersion)
        }

        return ToolchainPaths(
            root: root,
            colmap: colmap,
            glomap: colmap,
            brush: brush,
            msplat: msplat,
            da3: da3,
            mapanything: mapanything,
            vggt: vggt,
            fastvggt: fastvggt
        )
    }

    func ensureExecutable(at url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        if fileManager.isExecutableFile(atPath: url.path) { return }
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    func shouldRequireDa3ForToolchainValidation() -> Bool {
        guard let raw = RuntimeEnvironment.current["EASYSPLAT_SFM_BACKEND"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return true
        }
        switch raw {
        case "mapanything", "colmap", "glomap", "global_mapper", "vggt", "vggt-mps", "fastvggt":
            return false
        default:
            return true
        }
    }

    func validateBuildInfo(at url: URL, expectedToolchainName: String) throws {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ToolchainError.invalidToolchain("\(expectedToolchainName) build_info.json could not be read.")
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ToolchainError.invalidToolchain("\(expectedToolchainName) build_info.json is not valid JSON.")
        }

        guard let payload = object as? [String: Any] else {
            throw ToolchainError.invalidToolchain("\(expectedToolchainName) build_info.json must contain a JSON object.")
        }

        let requiredKeys = [
            "toolchain_name",
            "source_path",
            "python_version",
            "torch_version",
            "torchvision_version",
        ]
        let missingKeys = requiredKeys.filter {
            guard let value = payload[$0] else { return true }
            if let text = value as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        }
        if !missingKeys.isEmpty {
            throw ToolchainError.invalidToolchain(
                "\(expectedToolchainName) build_info.json is missing required keys: \(missingKeys.joined(separator: ", "))."
            )
        }

        let toolchainName = (payload["toolchain_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard toolchainName == expectedToolchainName else {
            throw ToolchainError.invalidToolchain(
                "\(expectedToolchainName) build_info.json toolchain_name mismatch (got \(toolchainName ?? "nil"))."
            )
        }
    }

    func validateNativeMsplatClosure(
        root: URL,
        executable: URL,
        metallib: URL,
        buildInfo: URL,
        license: URL
    ) throws -> String {
        let msplatRoot = root.appendingPathComponent("msplat", isDirectory: true)
        let expectedFiles = Set(["LICENSE", "build_info.json"])

        for url in [executable, metallib, msplatRoot, buildInfo, license] {
            if let symlink = firstSymbolicLinkComponent(from: root, through: url) {
                throw ToolchainError.invalidToolchain(
                    "Native msplat closure contains a symbolic link: \(projectRelativePath(symlink, root: root))."
                )
            }
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: msplatRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolchainError.missingLibrary("msplat")
        }
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: msplatRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: []
            )
        } catch {
            throw ToolchainError.invalidToolchain("Native msplat closure could not be enumerated.")
        }
        let names = Set(entries.map(\.lastPathComponent))
        guard names == expectedFiles else {
            let unexpected = names.subtracting(expectedFiles).sorted()
            let missing = expectedFiles.subtracting(names).sorted()
            var details: [String] = []
            if !unexpected.isEmpty { details.append("unexpected files: \(unexpected.joined(separator: ", "))") }
            if !missing.isEmpty { details.append("missing files: \(missing.joined(separator: ", "))") }
            throw ToolchainError.invalidToolchain("Native msplat closure has \(details.joined(separator: "; ")).")
        }

        let fileRequirements: [(url: URL, label: String, maximumBytes: Int64)] = [
            (executable, "bin/easysplat-train", 128 * 1_024 * 1_024),
            (metallib, "bin/default.metallib", 512 * 1_024 * 1_024),
            (buildInfo, "msplat/build_info.json", 64 * 1_024),
            (license, "msplat/LICENSE", 4 * 1_024 * 1_024),
        ]
        for requirement in fileRequirements {
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(atPath: requirement.url.path)
            } catch {
                throw ToolchainError.invalidToolchain(
                    "Native msplat closure entry could not be inspected: \(requirement.label)."
                )
            }
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw ToolchainError.invalidToolchain(
                    "Native msplat closure entry is not a regular file: \(requirement.label)."
                )
            }
            if let references = attributes[.referenceCount] as? NSNumber,
               references.intValue != 1 {
                throw ToolchainError.invalidToolchain(
                    "Native msplat closure entry is a multiply linked hard link: \(requirement.label)."
                )
            }
            guard let size = attributes[.size] as? NSNumber,
                  size.int64Value > 0,
                  size.int64Value <= requirement.maximumBytes else {
                throw ToolchainError.invalidToolchain(
                    "Native msplat closure entry has an invalid size: \(requirement.label)."
                )
            }
        }

        return try validateMsplatBuildInfo(at: buildInfo, executable: executable, metallib: metallib)
    }

    func validateMsplatBuildInfo(at url: URL, executable: URL, metallib: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ToolchainError.invalidToolchain("msplat build_info.json could not be read.")
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ToolchainError.invalidToolchain("msplat build_info.json is not valid JSON.")
        }

        guard let payload = object as? [String: Any] else {
            throw ToolchainError.invalidToolchain("msplat build_info.json must contain a JSON object.")
        }

        let requiredKeys = Set([
            "toolchain_name",
            "source_url",
            "source_commit",
            "source_version",
            "source_tree_sha256",
            "overlay_sha256",
            "patch_sha256",
            "dependencies",
            "executable_sha256",
            "metallib_sha256",
            "compiler",
            "cmake",
            "ninja",
            "deployment_target",
            "build_configuration",
            "cmake_arguments",
            "build_timestamp",
        ])
        let presentKeys = Set(payload.keys)
        let missingKeys = requiredKeys.subtracting(presentKeys).sorted()
        if !missingKeys.isEmpty {
            throw ToolchainError.invalidToolchain(
                "msplat build_info.json is missing required keys: \(missingKeys.joined(separator: ", "))."
            )
        }
        let unexpectedKeys = presentKeys.subtracting(requiredKeys).sorted()
        if !unexpectedKeys.isEmpty {
            throw ToolchainError.invalidToolchain(
                "msplat build_info.json contains unexpected keys: \(unexpectedKeys.joined(separator: ", "))."
            )
        }

        func requiredString(_ key: String) throws -> String {
            guard let value = payload[key] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolchainError.invalidToolchain("msplat build_info.json key \(key) must be a non-empty string.")
            }
            return value
        }

        let expectedValues = [
            "toolchain_name": "msplat",
            "source_url": "https://github.com/rayanht/msplat.git",
            "source_commit": "106499b0a53f82b0c92d013b0861fbebd341b17e",
            "source_version": "1.1.3",
            "deployment_target": "macOS 15.0",
            "build_configuration": "Release",
        ]
        for (key, expected) in expectedValues {
            let actual = try requiredString(key)
            guard actual == expected else {
                throw ToolchainError.invalidToolchain(
                    "msplat build_info.json \(key) mismatch (expected \(expected), got \(actual))."
                )
            }
        }

        let hashKeys = [
            "source_tree_sha256",
            "overlay_sha256",
            "patch_sha256",
            "executable_sha256",
            "metallib_sha256",
        ]
        for key in hashKeys {
            let value = try requiredString(key)
            guard isLowercaseSHA256(value) else {
                throw ToolchainError.invalidToolchain("msplat build_info.json \(key) must be a lowercase SHA-256 hash.")
            }
        }

        let expectedDependencies = [
            "nlohmann_json_v3.11.3_sha256": "04022b05d806eb5ff73023c280b68697d12b93e1b7267a0b22a1a39ec7578069",
            "nanoflann_v1.5.5_sha256": "57496cb27e1310a77a367e5a902c8f1c700496d91ac54ccc87fbe9ccc28bc6cc",
            "cli11_v2.4.2_sha256": "43e650d5e1a3acaaf419d1e61a81f77b408d0696f472be0599ddf877d40984b0",
        ]
        guard let dependencies = payload["dependencies"] as? [String: String],
              dependencies == expectedDependencies else {
            throw ToolchainError.invalidToolchain("msplat build_info.json dependencies do not match the pinned native closure.")
        }

        for key in ["compiler", "cmake", "ninja"] {
            _ = try requiredString(key)
        }
        let expectedArguments = [
            "-G Ninja",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DCMAKE_OSX_ARCHITECTURES=arm64",
            "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0",
            "-DMSPLAT_BUILD_PYTHON=OFF",
            "-DFETCHCONTENT_FULLY_DISCONNECTED=ON",
            "FETCHCONTENT_SOURCE_DIR_NLOHMANN_JSON=verified-v3.11.3",
            "FETCHCONTENT_SOURCE_DIR_NANOFLANN=verified-v1.5.5",
            "FETCHCONTENT_SOURCE_DIR_CLI11=verified-v2.4.2",
        ]
        guard let arguments = payload["cmake_arguments"] as? [String], arguments == expectedArguments else {
            throw ToolchainError.invalidToolchain("msplat build_info.json cmake_arguments do not match the pinned native build.")
        }
        let timestamp = try requiredString("build_timestamp")
        guard ISO8601DateFormatter().date(from: timestamp) != nil else {
            throw ToolchainError.invalidToolchain("msplat build_info.json build_timestamp is not ISO 8601.")
        }

        let executableHash = try sha256Hex(url: executable)
        guard executableHash == payload["executable_sha256"] as? String else {
            throw ToolchainError.invalidToolchain(
                "msplat build_info.json executable_sha256 mismatch."
            )
        }
        let metallibHash = try sha256Hex(url: metallib)
        guard metallibHash == payload["metallib_sha256"] as? String else {
            throw ToolchainError.invalidToolchain("msplat build_info.json metallib_sha256 mismatch.")
        }
        let sourceVersion = try requiredString("source_version")
        let sourceCommit = try requiredString("source_commit")
        return "\(sourceVersion) (git \(sourceCommit.prefix(7)))"
    }

    func validateMsplatSelfCheck(executable: URL, runtimeVersion: String) throws {
        let result: SubprocessResult
        do {
            result = try runner.run(executable.path, ["--self-check", "--events-fd", "1"])
        } catch {
            throw ToolchainError.invalidToolchain("easysplat-train self-check could not run (\(error.localizedDescription)).")
        }
        guard result.exitCode == 0, result.terminationReason == .exit else {
            throw ToolchainError.invalidToolchain("easysplat-train self-check failed (exit \(result.exitCode)).")
        }
        let line = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.contains("\n"), !line.contains("\r"),
              let data = line.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolchainError.invalidToolchain("easysplat-train self-check did not emit exactly one JSONL event.")
        }
        let expectedKeys = Set(["event", "schema_version", "sequence", "status", "version"])
        guard Set(event.keys) == expectedKeys,
              event["event"] as? String == "self_check",
              event["schema_version"] as? Int == 1,
              event["sequence"] as? Int == 1,
              event["status"] as? String == "ok",
              event["version"] as? String == runtimeVersion else {
            throw ToolchainError.invalidToolchain("easysplat-train self-check event is invalid.")
        }
    }

    func rejectLegacyMsplatFootprint(root: URL) throws {
        let legacyPaths = [
            root.appendingPathComponent("bin/msplat-train"),
            root.appendingPathComponent("msplat/bin"),
            root.appendingPathComponent("msplat/python"),
            root.appendingPathComponent("msplat/core_extension_path.txt"),
        ]
        if let legacy = legacyPaths.first(where: { pathExistsIncludingSymlink($0) }) {
            throw ToolchainError.invalidToolchain(
                "Remove the legacy msplat footprint at \(projectRelativePath(legacy, root: root))."
            )
        }
    }

    func pathExistsIncludingSymlink(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path) || isSymbolicLink(url)
    }

    func isSymbolicLink(_ url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeSymbolicLink
    }

    func firstSymbolicLinkComponent(from root: URL, through candidate: URL) -> URL? {
        let root = root.standardizedFileURL
        var current = candidate.standardizedFileURL
        guard current.path == root.path || current.path.hasPrefix(root.path + "/") else {
            return current
        }
        while true {
            if isSymbolicLink(current) {
                return current
            }
            if current.path == root.path {
                return nil
            }
            let parent = current.deletingLastPathComponent()
            guard parent.path != current.path else { return current }
            current = parent
        }
    }

    func projectRelativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return url.lastPathComponent }
        return String(path.dropFirst(rootPath.count + 1))
    }

    func isLowercaseSHA256(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.unicodeScalars.allSatisfy {
            ("0"..."9").contains(Character(String($0))) || ("a"..."f").contains(Character(String($0)))
        }
    }

    /// Verifies the binary at `url` is a native arm64 Mach-O. Fails closed if `/usr/bin/file`
    /// cannot be executed at all — we'd rather block startup than silently allow a Rosetta build.
    /// Uses `-b` to strip the filename from output so paths containing "arm64" (e.g.
    /// `…/index-build/arm64-apple-macosx/…`) cannot satisfy the substring check on their own.
    func requireArm64Binary(at url: URL, label: String) throws {
        let probe: SubprocessResult
        do {
            probe = try runner.run("/usr/bin/file", ["-b", url.path])
        } catch {
            throw ToolchainError.invalidToolchain(
                "\(label) architecture check could not run (\(error.localizedDescription))."
            )
        }
        guard probe.exitCode == 0 else {
            throw ToolchainError.invalidToolchain(
                "\(label) architecture check failed (file exited \(probe.exitCode))."
            )
        }
        let description = probe.stdout.lowercased()
        guard description.contains("mach-o") else {
            throw ToolchainError.invalidToolchain(
                "\(label) is not a Mach-O binary (file reported: \(probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))."
            )
        }
        // Universal binaries report each slice; require at least one arm64 slice.
        guard description.contains("arm64") else {
            throw ToolchainError.invalidToolchain("\(label) is not arm64 (Rosetta build detected).")
        }
    }

    func fileHasShebang(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2), data.count == 2 else { return false }
        return data[0] == 0x23 && data[1] == 0x21
    }

    func artifactLooksInstalled(name: String, root: URL) -> Bool {
        if name.hasSuffix("-core") {
            return coreToolchainLooksInstalled(root: root)
        }
        if name.hasSuffix("-models") {
            return modelsToolchainLooksInstalled(root: root)
        }
        return false
    }

    func coreToolchainLooksInstalled(root: URL) -> Bool {
        let colmap = root.appendingPathComponent("bin/colmap")
        let brush = root.appendingPathComponent("bin/brush")
        let brushReal = root.appendingPathComponent("bin/brush.real")
        let libcrypto = root.appendingPathComponent("lib/libcrypto.3.dylib")
        let libssl = root.appendingPathComponent("lib/libssl.3.dylib")
        let msplat = root.appendingPathComponent("msplat", isDirectory: true)
        let msplatTrain = root.appendingPathComponent("bin/easysplat-train")
        let msplatMetallib = root.appendingPathComponent("bin/default.metallib")
        let msplatBuildInfo = msplat.appendingPathComponent("build_info.json")
        let msplatLicense = msplat.appendingPathComponent("LICENSE")
        let da3 = root.appendingPathComponent("da3_mps", isDirectory: true)
        let da3SfmTool = da3.appendingPathComponent("bin/easysplat_da3_sfm")
        let da3Python = da3.appendingPathComponent("python/bin/python3")
        let da3BuildInfo = da3.appendingPathComponent("build_info.json")
        let da3AppSentinel = da3.appendingPathComponent("app/easysplat_da3_sfm/run.py")
        let da3VendorSentinel = da3.appendingPathComponent("vendor/depth-anything-3/src/depth_anything_3/api.py")
        let vggt = root.appendingPathComponent("vggt_mps", isDirectory: true)
        let vggtSfmTool = vggt.appendingPathComponent("bin/easysplat_vggt_sfm")
        let vggtPython = vggt.appendingPathComponent("python/bin/python3")
        let vggtBuildInfo = vggt.appendingPathComponent("build_info.json")
        let vggtAppSentinel = vggt.appendingPathComponent("app/easysplat_vggt_sfm/run.py")
        let vggtVendorSentinel = vggt.appendingPathComponent("vendor/vggt/vggt/models/vggt.py")
        let mapanything = root.appendingPathComponent("mapanything_mps", isDirectory: true)
        let mapAnythingSfmTool = mapanything.appendingPathComponent("bin/easysplat_mapanything_sfm")
        let mapAnythingPython = mapanything.appendingPathComponent("python/bin/python3")
        let mapAnythingBuildInfo = mapanything.appendingPathComponent("build_info.json")
        let mapAnythingAppSentinel = mapanything.appendingPathComponent("app/easysplat_mapanything_sfm/run.py")
        let mapAnythingVendorSentinel = mapanything.appendingPathComponent("vendor/mapanything/mapanything/models/mapanything/model.py")
        let fastvggt = root.appendingPathComponent("fastvggt_mps", isDirectory: true)
        let fastvggtSfmTool = fastvggt.appendingPathComponent("bin/easysplat_fastvggt_sfm")
        let fastvggtPython = fastvggt.appendingPathComponent("python/bin/python3")
        let fastvggtBuildInfo = fastvggt.appendingPathComponent("build_info.json")
        let fastvggtAppSentinel = fastvggt.appendingPathComponent("app/easysplat_fastvggt_sfm/run.py")
        let fastvggtVendorSentinel = fastvggt.appendingPathComponent("vendor/fastvggt/vggt/models/vggt.py")

        let brushOK: Bool = {
            guard fileManager.isExecutableFile(atPath: brush.path) else { return false }
            if fileHasShebang(at: brush) {
                return fileManager.isExecutableFile(atPath: brushReal.path)
            }
            return true
        }()
        let msplatEntries = [msplatTrain, msplatMetallib, msplat, msplatBuildInfo, msplatLicense]
        let msplatPresent = msplatEntries.contains { pathExistsIncludingSymlink($0) }
        let legacyMsplatPresent = [
            root.appendingPathComponent("bin/msplat-train"),
            root.appendingPathComponent("msplat/bin"),
            root.appendingPathComponent("msplat/python"),
            root.appendingPathComponent("msplat/core_extension_path.txt"),
        ].contains { pathExistsIncludingSymlink($0) }
        let msplatOK = !legacyMsplatPresent
            && (
                !msplatPresent
                    || (
                    !isSymbolicLink(msplatTrain)
                    && fileManager.isExecutableFile(atPath: msplatTrain.path)
                    && (try? validateNativeMsplatClosure(
                        root: root,
                        executable: msplatTrain,
                        metallib: msplatMetallib,
                        buildInfo: msplatBuildInfo,
                        license: msplatLicense
                    )) != nil
                    )
            )

        return fileManager.isExecutableFile(atPath: colmap.path)
            && brushOK
            && msplatOK
            && fileManager.fileExists(atPath: libcrypto.path)
            && fileManager.fileExists(atPath: libssl.path)
            && fileManager.fileExists(atPath: da3SfmTool.path)
            && fileManager.fileExists(atPath: da3Python.path)
            && fileManager.fileExists(atPath: da3BuildInfo.path)
            && fileManager.fileExists(atPath: da3AppSentinel.path)
            && fileManager.fileExists(atPath: da3VendorSentinel.path)
            && fileManager.fileExists(atPath: mapAnythingSfmTool.path)
            && fileManager.fileExists(atPath: mapAnythingPython.path)
            && fileManager.fileExists(atPath: mapAnythingBuildInfo.path)
            && fileManager.fileExists(atPath: mapAnythingAppSentinel.path)
            && fileManager.fileExists(atPath: mapAnythingVendorSentinel.path)
            && fileManager.fileExists(atPath: vggtSfmTool.path)
            && fileManager.fileExists(atPath: vggtPython.path)
            && fileManager.fileExists(atPath: vggtBuildInfo.path)
            && fileManager.fileExists(atPath: vggtAppSentinel.path)
            && fileManager.fileExists(atPath: vggtVendorSentinel.path)
            && fileManager.fileExists(atPath: fastvggtSfmTool.path)
            && fileManager.fileExists(atPath: fastvggtPython.path)
            && fileManager.fileExists(atPath: fastvggtBuildInfo.path)
            && fileManager.fileExists(atPath: fastvggtAppSentinel.path)
            && fileManager.fileExists(atPath: fastvggtVendorSentinel.path)
    }

    func modelsToolchainLooksInstalled(root: URL) -> Bool {
        let mapAnythingModel = root
            .appendingPathComponent("mapanything_mps/models/map-anything-apache/model.safetensors")
        let mapAnythingConfig = root
            .appendingPathComponent("mapanything_mps/models/map-anything-apache/config.json")
        let mapAnythingDinov2 = root
            .appendingPathComponent("mapanything_mps/models/dinov2/dinov2_vitg14_pretrain.pth")
        let da3BaseModel = root
            .appendingPathComponent("da3_mps/models/DA3-BASE/model.safetensors")
        let da3BaseConfig = root
            .appendingPathComponent("da3_mps/models/DA3-BASE/config.json")
        let da3BaseInfo = root
            .appendingPathComponent("da3_mps/models/DA3-BASE/easysplat_model_info.json")
        let da3SmallModel = root
            .appendingPathComponent("da3_mps/models/DA3-SMALL/model.safetensors")
        let da3SmallConfig = root
            .appendingPathComponent("da3_mps/models/DA3-SMALL/config.json")
        let da3SmallInfo = root
            .appendingPathComponent("da3_mps/models/DA3-SMALL/easysplat_model_info.json")
        let vggtModel = root
            .appendingPathComponent("vggt_mps/models/vggt_model.pt")
        let fastvggtModel = root
            .appendingPathComponent("fastvggt_mps/models/fastvggt_model.pt")
        return fileManager.fileExists(atPath: mapAnythingModel.path)
            && fileManager.fileExists(atPath: mapAnythingConfig.path)
            && fileManager.fileExists(atPath: mapAnythingDinov2.path)
            && fileManager.fileExists(atPath: da3BaseModel.path)
            && fileManager.fileExists(atPath: da3BaseConfig.path)
            && fileManager.fileExists(atPath: da3BaseInfo.path)
            && fileManager.fileExists(atPath: da3SmallModel.path)
            && fileManager.fileExists(atPath: da3SmallConfig.path)
            && fileManager.fileExists(atPath: da3SmallInfo.path)
            && fileManager.fileExists(atPath: vggtModel.path)
            && fileManager.fileExists(atPath: fastvggtModel.path)
    }
}
