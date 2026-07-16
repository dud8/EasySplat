import Foundation

extension ToolchainManager {
    func validateToolchain(
        root: URL,
        requiredCapabilities: Set<ToolchainCapability>
    ) throws -> ToolchainPaths {
        let colmap = root.appendingPathComponent("bin/colmap")
        ensureExecutable(at: colmap)
        guard fileManager.isExecutableFile(atPath: colmap.path) else { throw ToolchainError.missingBinary("colmap") }

        try requireArm64Binary(at: colmap, label: "colmap")

        let colmapCheck: SubprocessResult
        do {
            colmapCheck = try runner.run(colmap.path, ["-h"])
        } catch {
            throw ToolchainError.invalidToolchain("COLMAP could not be launched.")
        }
        guard colmapCheck.terminationReason == .exit, colmapCheck.exitCode == 0 else {
            throw ToolchainError.invalidToolchain("COLMAP failed to launch (exit \(colmapCheck.exitCode)).")
        }
        try validateColmapBridgeRoot(colmapCheck)
        try validateColmapRuntime(executable: colmap)

        let mapperProbe: SubprocessResult
        do {
            mapperProbe = try runner.run(colmap.path, ["mapper", "-h"])
        } catch {
            throw ToolchainError.invalidToolchain("COLMAP mapper could not be launched.")
        }
        guard mapperProbe.terminationReason == .exit, mapperProbe.exitCode == 0 else {
            let text = "\(mapperProbe.stdout)\n\(mapperProbe.stderr)".lowercased()
            if text.contains("library not loaded") || text.contains("no lc_rpath") {
                throw ToolchainError.invalidToolchain("COLMAP mapper failed to launch (missing dylib/rpath).")
            }
            if text.contains("not recognized") || text.contains("unknown command") || text.contains("unrecognized command") {
                throw ToolchainError.invalidToolchain("COLMAP does not include the required mapper command.")
            }
            throw ToolchainError.invalidToolchain("COLMAP mapper self-check failed (exit \(mapperProbe.exitCode)).")
        }
        try requireColmapHelpTokens(
            ColmapBridgeContract.mapperOptions,
            in: mapperProbe,
            subject: "COLMAP mapper"
        )

        let vocabularyProbe: SubprocessResult
        do {
            vocabularyProbe = try runner.run(colmap.path, ["local_vocab_retriever", "-h"])
        } catch {
            throw ToolchainError.invalidToolchain("COLMAP local_vocab_retriever could not be launched.")
        }
        guard vocabularyProbe.terminationReason == .exit, vocabularyProbe.exitCode == 0 else {
            let text = "\(vocabularyProbe.stdout)\n\(vocabularyProbe.stderr)".lowercased()
            if text.contains("not recognized") || text.contains("unknown command") || text.contains("unrecognized command") {
                throw ToolchainError.invalidToolchain(
                    "COLMAP does not include the required local_vocab_retriever command."
                )
            }
            throw ToolchainError.invalidToolchain(
                "COLMAP local_vocab_retriever self-check failed (exit \(vocabularyProbe.exitCode))."
            )
        }
        try requireColmapHelpTokens(
            ColmapBridgeContract.vocabularyOptions,
            in: vocabularyProbe,
            subject: "COLMAP local_vocab_retriever"
        )

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
        let needsBase = requiredCapabilities.contains(.da3Base)
        let needsSmall = requiredCapabilities.contains(.da3Small)
        if needsBase || needsSmall {
            guard fileManager.fileExists(atPath: da3Models.path) else {
                throw ToolchainError.missingLibrary("da3_mps/models")
            }
        }
        if needsBase {
            guard fileManager.fileExists(atPath: da3BaseModelFile.path) else {
                throw ToolchainError.missingLibrary("da3_mps/models/DA3-BASE/model.safetensors")
            }
            guard fileManager.fileExists(atPath: da3BaseConfigFile.path) else {
                throw ToolchainError.missingLibrary("da3_mps/models/DA3-BASE/config.json")
            }
            guard fileManager.fileExists(atPath: da3BaseModelInfoFile.path) else {
                throw ToolchainError.missingLibrary("da3_mps/models/DA3-BASE/easysplat_model_info.json")
            }
        }
        if needsSmall {
            guard fileManager.fileExists(atPath: da3SmallModelFile.path) else {
                throw ToolchainError.missingLibrary("da3_mps/models/DA3-SMALL/model.safetensors")
            }
            guard fileManager.fileExists(atPath: da3SmallConfigFile.path) else {
                throw ToolchainError.missingLibrary("da3_mps/models/DA3-SMALL/config.json")
            }
            guard fileManager.fileExists(atPath: da3SmallModelInfoFile.path) else {
                throw ToolchainError.missingLibrary("da3_mps/models/DA3-SMALL/easysplat_model_info.json")
            }
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

        let da3 = Da3Toolchain(
            root: da3Root,
            sfmTool: da3SfmTool,
            python: da3Python,
            models: da3Models,
            modelBundle: da3ModelBundle,
            fallbackModelBundle: da3FallbackModelBundle
        )

        let msplat = root.appendingPathComponent("bin/easysplat-train")
        let msplatMetallib = root.appendingPathComponent("bin/default.metallib")
        let msplatRoot = root.appendingPathComponent("msplat", isDirectory: true)
        let msplatBuildInfo = msplatRoot.appendingPathComponent("build_info.json")
        let msplatLicense = msplatRoot.appendingPathComponent("LICENSE")
        try rejectLegacyMsplatFootprint(root: root)
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

        return ToolchainPaths(
            root: root,
            colmap: colmap,
            msplat: msplat,
            da3: da3
        )
    }

    func ensureExecutable(at url: URL) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        if fileManager.isExecutableFile(atPath: url.path) { return }
        try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func validateColmapBridgeRoot(_ result: SubprocessResult) throws {
        let lines = colmapHelpLines(in: result)
        let hasReviewedRuntime = lines.contains { line in
            let fields = line.split(whereSeparator: \Character.isWhitespace)
            return fields.count >= 2
                && fields[0] == "pycolmap"
                && fields[1] == Substring(ColmapBridgeContract.pycolmapVersion)
        }
        guard hasReviewedRuntime else {
            throw ToolchainError.invalidToolchain(
                "COLMAP bridge requires the reviewed pycolmap \(ColmapBridgeContract.pycolmapVersion) runtime."
            )
        }

        var insideCommands = false
        var commands = Set<String>()
        for line in lines {
            if line == "Commands:" {
                insideCommands = true
                continue
            }
            guard insideCommands else { continue }
            let fields = line.split(whereSeparator: \Character.isWhitespace)
            if fields.count == 1 {
                commands.insert(String(fields[0]))
            }
        }
        let missing = ColmapBridgeContract.commands.subtracting(commands).sorted()
        if !missing.isEmpty {
            let suffix = missing.count == 1 ? "" : "s"
            throw ToolchainError.invalidToolchain(
                "COLMAP bridge is missing required command\(suffix): \(missing.joined(separator: ", "))."
            )
        }
    }

    private func validateColmapRuntime(executable: URL) throws {
        let result: SubprocessResult
        do {
            result = try runner.run(executable.path, ["--self-check"])
        } catch {
            throw ToolchainError.invalidToolchain("COLMAP runtime self-check could not be launched.")
        }
        guard result.terminationReason == .exit, result.exitCode == 0 else {
            throw ToolchainError.invalidToolchain(
                "COLMAP runtime self-check failed (exit \(result.exitCode))."
            )
        }

        guard let data = result.stdout.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(payload.keys) == ["runtime", "runtime_version", "schema_version", "status"],
              payload["schema_version"] as? Int == 1,
              payload["status"] as? String == "ok",
              payload["runtime"] as? String == "pycolmap",
              payload["runtime_version"] as? String == ColmapBridgeContract.pycolmapVersion else {
            throw ToolchainError.invalidToolchain("COLMAP runtime self-check returned an invalid result.")
        }
    }

    private func requireColmapHelpTokens(
        _ required: Set<String>,
        in result: SubprocessResult,
        subject: String
    ) throws {
        let declaredOptions = Set(colmapHelpLines(in: result).compactMap { line -> String? in
            guard line.hasPrefix("--") else { return nil }
            let option = line.dropFirst(2).prefix { character in
                character.isLetter || character.isNumber || character == "_" || character == "."
            }
            return option.isEmpty ? nil : String(option)
        })
        let missing = required.subtracting(declaredOptions).sorted()
        guard missing.isEmpty else {
            let suffix = missing.count == 1 ? "" : "s"
            throw ToolchainError.invalidToolchain(
                "\(subject) is missing required option\(suffix): \(missing.joined(separator: ", "))."
            )
        }
    }

    private func colmapHelpLines(in result: SubprocessResult) -> [String] {
        "\(result.stdout)\n\(result.stderr)"
            .split(whereSeparator: \Character.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    func validateBuildInfo(at url: URL, expectedToolchainName: String) throws {
        let data: Data
        do {
            data = try BoundedFileReader.readRegularFile(
                at: url,
                maximumBytes: 1_048_576
            )
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
            "raster_test_sha256",
            "patch_sha256",
            "checkpoint_patch_sha256",
            "densification_memory_patch_sha256",
            "numeric_stability_patch_sha256",
            "metal_safety_patch_sha256",
            "exact_raster_patch_sha256",
            "stage_timing_patch_sha256",
            "memory_efficiency_patch_sha256",
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
            "overlay_sha256": "cfefabcf9366571241e5a0923ae35fa3b8b263d6d024a87485bccc2e842ad29e",
            "raster_test_sha256": "6f4a180d75bda88f39379b9be8521e63e1a76ecb507c1841ec113673d6bef110",
            "exact_raster_patch_sha256": "278deba531d1503b8f6fe3428e0b6c5103129f388a6bc425c41780ff9e4c453b",
            "stage_timing_patch_sha256": "41e7146c2047a7a93b45927d1ee40d1e310db9898c25ab892a27c158acff75dd",
            "memory_efficiency_patch_sha256": "bfacc105454e80102139f120dd6375037360c6a9763f1e1f708aa2a7f22eca6c",
            "densification_memory_patch_sha256": "b429540372d807f280929ebba1670257990bd36b28dfee5b42bc377ccef60ac7",
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
            "raster_test_sha256",
            "patch_sha256",
            "checkpoint_patch_sha256",
            "numeric_stability_patch_sha256",
            "metal_safety_patch_sha256",
            "exact_raster_patch_sha256",
            "stage_timing_patch_sha256",
            "memory_efficiency_patch_sha256",
            "densification_memory_patch_sha256",
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
            "-DMSPLAT_BUILD_RASTER_TESTS=ON",
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
        let expectedKeys = Set([
            "event",
            "scene_bounds_status",
            "schema_version",
            "sequence",
            "status",
            "version",
        ])
        guard Set(event.keys) == expectedKeys,
              event["event"] as? String == "self_check",
              event["scene_bounds_status"] as? String == "ok",
              event["schema_version"] as? Int == 2,
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
        let architectures = Set(
            description
                .split { !$0.isLetter && !$0.isNumber && $0 != "_" }
                .map(String.init)
                .filter { $0 == "arm64" || $0 == "arm64e" || $0 == "x86_64" || $0 == "i386" }
        )
        guard architectures == ["arm64"], !description.contains("universal binary") else {
            throw ToolchainError.invalidToolchain(
                "\(label) must be an arm64-only Mach-O binary."
            )
        }
    }

    func artifactLooksInstalled(name: String, root: URL) -> Bool {
        if name == "geometry-da3-base" {
            return da3ModelLooksInstalled(named: "DA3-BASE", root: root)
        }
        if name == "geometry-da3-small" {
            return da3ModelLooksInstalled(named: "DA3-SMALL", root: root)
        }
        if name.hasSuffix("-core") {
            return coreToolchainLooksInstalled(root: root)
        }
        if name.hasSuffix("-models") {
            return modelsToolchainLooksInstalled(root: root)
        }
        return false
    }

    func da3ModelLooksInstalled(named modelName: String, root: URL) -> Bool {
        let bundle = root.appendingPathComponent("da3_mps/models/\(modelName)", isDirectory: true)
        return fileManager.fileExists(atPath: bundle.appendingPathComponent("model.safetensors").path)
            && fileManager.fileExists(atPath: bundle.appendingPathComponent("config.json").path)
            && fileManager.fileExists(atPath: bundle.appendingPathComponent("easysplat_model_info.json").path)
    }

    func coreToolchainLooksInstalled(root: URL) -> Bool {
        let colmap = root.appendingPathComponent("bin/colmap")
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
        let legacyMsplatPresent = [
            root.appendingPathComponent("bin/msplat-train"),
            root.appendingPathComponent("msplat/bin"),
            root.appendingPathComponent("msplat/python"),
            root.appendingPathComponent("msplat/core_extension_path.txt"),
        ].contains { pathExistsIncludingSymlink($0) }
        let msplatOK = !legacyMsplatPresent
            && !isSymbolicLink(msplatTrain)
            && fileManager.isExecutableFile(atPath: msplatTrain.path)
            && (try? validateNativeMsplatClosure(
                root: root,
                executable: msplatTrain,
                metallib: msplatMetallib,
                buildInfo: msplatBuildInfo,
                license: msplatLicense
            )) != nil

        return fileManager.isExecutableFile(atPath: colmap.path)
            && msplatOK
            && fileManager.fileExists(atPath: da3SfmTool.path)
            && fileManager.fileExists(atPath: da3Python.path)
            && fileManager.fileExists(atPath: da3BuildInfo.path)
            && fileManager.fileExists(atPath: da3AppSentinel.path)
            && fileManager.fileExists(atPath: da3VendorSentinel.path)
    }

    func modelsToolchainLooksInstalled(root: URL) -> Bool {
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
        return fileManager.fileExists(atPath: da3BaseModel.path)
            && fileManager.fileExists(atPath: da3BaseConfig.path)
            && fileManager.fileExists(atPath: da3BaseInfo.path)
            && fileManager.fileExists(atPath: da3SmallModel.path)
            && fileManager.fileExists(atPath: da3SmallConfig.path)
            && fileManager.fileExists(atPath: da3SmallInfo.path)
    }
}

private enum ColmapBridgeContract {
    static let pycolmapVersion = "4.1.0"

    static let commands: Set<String> = [
        "feature_extractor",
        "matches_importer",
        "local_vocab_retriever",
        "mapper",
        "point_triangulator",
        "bundle_adjuster",
        "model_analyzer",
        "image_undistorter",
        "model_converter",
    ]

    static let mapperOptions: Set<String> = [
        "database_path",
        "image_path",
        "output_path",
        "Mapper.ba_global_frames_ratio",
        "Mapper.ba_global_points_ratio",
        "Mapper.ba_local_max_refinements",
        "Mapper.ba_global_max_refinements",
        "Mapper.ba_global_max_num_iterations",
        "Mapper.ba_local_max_num_iterations",
        "Mapper.ba_local_function_tolerance",
        "Mapper.ba_global_function_tolerance",
        "Mapper.ba_local_num_images",
        "Mapper.random_seed",
        "Mapper.ba_refine_focal_length",
    ]

    static let vocabularyOptions: Set<String> = [
        "database_path",
        "output_pair_list_path",
        "query_image_list_path",
        "excluded_pair_list_path",
        "num_images",
        "returned_neighbor_count",
        "minimum_frame_separation",
        "num_visual_words",
        "max_features_per_image",
        "max_training_descriptors",
        "num_iterations",
        "num_rounds",
        "num_checks",
        "num_threads",
    ]
}
