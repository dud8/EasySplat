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

        let mapAnythingPythonArch = try? runner.run("/usr/bin/file", [mapAnythingPython.path])
        if let output = mapAnythingPythonArch?.stdout.lowercased(), !output.contains("arm64") {
            throw ToolchainError.invalidToolchain("mapanything_mps python is not arm64 (Rosetta build detected).")
        }
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

        let vggtPythonArch = try? runner.run("/usr/bin/file", [vggtPython.path])
        if let output = vggtPythonArch?.stdout.lowercased(), !output.contains("arm64") {
            throw ToolchainError.invalidToolchain("vggt_mps python is not arm64 (Rosetta build detected).")
        }
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

        let fastvggtPythonArch = try? runner.run("/usr/bin/file", [fastvggtPython.path])
        if let output = fastvggtPythonArch?.stdout.lowercased(), !output.contains("arm64") {
            throw ToolchainError.invalidToolchain("fastvggt_mps python is not arm64 (Rosetta build detected).")
        }
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

        let glomap = colmap

        return ToolchainPaths(
            root: root,
            colmap: colmap,
            glomap: glomap,
            brush: brush,
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

        return fileManager.isExecutableFile(atPath: colmap.path)
            && brushOK
            && fileManager.fileExists(atPath: libcrypto.path)
            && fileManager.fileExists(atPath: libssl.path)
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
        let vggtModel = root
            .appendingPathComponent("vggt_mps/models/vggt_model.pt")
        let fastvggtModel = root
            .appendingPathComponent("fastvggt_mps/models/fastvggt_model.pt")
        return fileManager.fileExists(atPath: mapAnythingModel.path)
            && fileManager.fileExists(atPath: mapAnythingConfig.path)
            && fileManager.fileExists(atPath: mapAnythingDinov2.path)
            && fileManager.fileExists(atPath: vggtModel.path)
            && fileManager.fileExists(atPath: fastvggtModel.path)
    }
}
