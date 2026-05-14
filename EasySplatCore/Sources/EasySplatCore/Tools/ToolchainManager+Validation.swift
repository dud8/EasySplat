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

        let msplat = root.appendingPathComponent("bin/msplat-train")
        let msplatRoot = root.appendingPathComponent("msplat", isDirectory: true)
        let msplatBundledTrain = msplatRoot.appendingPathComponent("bin/msplat-train")
        let msplatPython = msplatRoot.appendingPathComponent("python/bin/python3")
        let msplatBuildInfo = msplatRoot.appendingPathComponent("build_info.json")
        let msplatCoreSentinel = msplatRoot.appendingPathComponent("core_extension_path.txt")
        let msplatEntries = [msplat, msplatBundledTrain, msplatPython, msplatBuildInfo, msplatCoreSentinel]
        let hasMsplatBundle = msplatEntries.contains { fileManager.fileExists(atPath: $0.path) }
        if hasMsplatBundle {
            guard fileManager.fileExists(atPath: msplat.path) else {
                throw ToolchainError.missingBinary("bin/msplat-train")
            }
            guard fileManager.fileExists(atPath: msplatBundledTrain.path) else {
                throw ToolchainError.missingBinary("msplat/bin/msplat-train")
            }
            guard fileManager.fileExists(atPath: msplatPython.path) else {
                throw ToolchainError.missingBinary("msplat/python/bin/python3")
            }
            guard fileManager.fileExists(atPath: msplatBuildInfo.path) else {
                throw ToolchainError.missingLibrary("msplat/build_info.json")
            }
            guard fileManager.fileExists(atPath: msplatCoreSentinel.path) else {
                throw ToolchainError.missingLibrary("msplat/core_extension_path.txt")
            }
            let msplatCoreExtension = try msplatCoreExtensionURL(root: msplatRoot, sentinel: msplatCoreSentinel)

            ensureExecutable(at: msplat)
            ensureExecutable(at: msplatBundledTrain)
            ensureExecutable(at: msplatPython)
            try validateMsplatBuildInfo(at: msplatBuildInfo)

            try requireArm64Binary(at: msplatPython, label: "msplat python")
            try requireArm64Binary(at: msplatCoreExtension, label: "msplat core extension")
            let msplatCheck = try runner.run(msplat.path, ["--help"])
            guard msplatCheck.exitCode == 0 else {
                throw ToolchainError.invalidToolchain("msplat-train failed to launch (exit \(msplatCheck.exitCode)).")
            }
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
        guard let raw = ProcessInfo.processInfo.environment["EASYSPLAT_SFM_BACKEND"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
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

    func validateMsplatBuildInfo(at url: URL) throws {
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

        let requiredKeys = [
            "toolchain_name",
            "source_path",
            "python_version",
            "package_version",
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
                "msplat build_info.json is missing required keys: \(missingKeys.joined(separator: ", "))."
            )
        }

        let toolchainName = (payload["toolchain_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard toolchainName == "msplat" else {
            throw ToolchainError.invalidToolchain(
                "msplat build_info.json toolchain_name mismatch (got \(toolchainName ?? "nil"))."
            )
        }
    }

    func msplatCoreExtensionURL(root: URL, sentinel: URL) throws -> URL {
        let relativePath: String
        do {
            relativePath = try String(contentsOf: sentinel, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw ToolchainError.invalidToolchain("msplat core_extension_path.txt could not be read.")
        }

        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              relativePath.rangeOfCharacter(from: .newlines) == nil else {
            throw ToolchainError.invalidToolchain("msplat core_extension_path.txt contains an invalid relative path.")
        }

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ToolchainError.invalidToolchain("msplat core_extension_path.txt contains an invalid relative path.")
        }
        let componentStrings = components.map(String.init)
        guard componentStrings.count >= 6,
              componentStrings[0] == "python",
              componentStrings[1] == "lib",
              componentStrings.contains("site-packages"),
              componentStrings.dropLast().last == "msplat",
              let fileName = componentStrings.last,
              fileName.hasPrefix("_core"),
              fileName.hasSuffix(".so") else {
            throw ToolchainError.invalidToolchain("msplat core_extension_path.txt must point at msplat/_core*.so in site-packages.")
        }

        var coreExtension = root
        for component in components {
            coreExtension = coreExtension.appendingPathComponent(String(component))
        }
        guard fileManager.fileExists(atPath: coreExtension.path) else {
            throw ToolchainError.missingLibrary("msplat/\(relativePath)")
        }
        return coreExtension
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
        let msplatTrain = root.appendingPathComponent("bin/msplat-train")
        let msplatBundledTrain = msplat.appendingPathComponent("bin/msplat-train")
        let msplatPython = msplat.appendingPathComponent("python/bin/python3")
        let msplatBuildInfo = msplat.appendingPathComponent("build_info.json")
        let msplatCoreSentinel = msplat.appendingPathComponent("core_extension_path.txt")
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
        let msplatEntries = [msplatTrain, msplatBundledTrain, msplatPython, msplatBuildInfo, msplatCoreSentinel]
        let msplatPresent = msplatEntries.contains { fileManager.fileExists(atPath: $0.path) }
        let msplatOK = !msplatPresent
            || (
                fileManager.isExecutableFile(atPath: msplatTrain.path)
                    && fileManager.isExecutableFile(atPath: msplatBundledTrain.path)
                    && fileManager.isExecutableFile(atPath: msplatPython.path)
                    && fileManager.fileExists(atPath: msplatBuildInfo.path)
                    && (try? msplatCoreExtensionURL(root: msplat, sentinel: msplatCoreSentinel)) != nil
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
