import Darwin
import XCTest
@testable import EasySplatCore

@MainActor
final class ToolchainManagerTests: XCTestCase {
    func testValidateToolchainSucceeds() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let runner = makeValidationRunner(root: root)

        let manager = ToolchainManager(runner: runner)
        let toolchain = try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small])
        XCTAssertEqual(toolchain.root, root)
        XCTAssertEqual(toolchain.colmap, root.appendingPathComponent("bin/colmap"))
        XCTAssertEqual(toolchain.msplat, root.appendingPathComponent("bin/easysplat-train"))
        XCTAssertEqual(toolchain.da3.root, root.appendingPathComponent("da3_mps", isDirectory: true))
    }

    func testValidateToolchainRejectsBrokenMapperLinkage() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let runner = makeValidationRunner(
            root: root,
            mapperExitCode: 1,
            mapperStderr: "Library not loaded: @rpath/libceres.4.dylib"
        )

        let manager = ToolchainManager(runner: runner)
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small])) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error, got \(error)")
            }
            XCTAssertTrue(message.contains("mapper"))
        }
    }

    func testValidateToolchainRejectsMissingMapperCommand() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let runner = makeValidationRunner(
            root: root,
            mapperExitCode: 1,
            mapperStderr: "ERROR: command `mapper` not recognized"
        )

        let manager = ToolchainManager(runner: runner)
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small])) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error, got \(error)")
            }
            XCTAssertTrue(message.contains("required mapper"))
        }
    }

    func testValidateToolchainRejectsMissingRequiredColmapCommand() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let runner = makeValidationRunner(
            root: root,
            colmapHelpStdout: NativeColmapHelpFixture.root.replacingOccurrences(
                of: "  local_vocab_retriever\n",
                with: ""
            )
        )

        let manager = ToolchainManager(runner: runner)
        XCTAssertThrowsError(
            try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base])
        ) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error, got \(error)")
            }
            XCTAssertTrue(message.contains("local_vocab_retriever"), "expected missing command name; got \(message)")
        }
    }

    func testValidateToolchainRejectsUnreviewedColmapCommand() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let runner = makeValidationRunner(
            root: root,
            colmapHelpStdout: NativeColmapHelpFixture.root.replacingOccurrences(
                of: "  feature_extractor\n",
                with: "  feature_extractor\n  exhaustive_matcher\n"
            )
        )

        let manager = ToolchainManager(runner: runner)
        XCTAssertThrowsError(
            try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base])
        ) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error, got \(error)")
            }
            XCTAssertTrue(message.contains("exhaustive_matcher"), "expected unexpected command name; got \(message)")
        }
    }

    func testValidateToolchainRejectsMissingRequiredMapperOptions() throws {
        for option in NativeColmapHelpFixture.mapperOptions {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try ToolchainFixtureBuilder.createToolchain(at: root)

            let runner = makeValidationRunner(
                root: root,
                mapperStdout: NativeColmapHelpFixture.mapper.replacingOccurrences(
                    of: "  --\(option) <value>\n",
                    with: ""
                )
            )

            let manager = ToolchainManager(runner: runner)
            XCTAssertThrowsError(
                try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base]),
                "Expected missing option rejection for \(option)"
            ) { error in
                guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                    return XCTFail("Expected invalidToolchain error for \(option), got \(error)")
                }
                XCTAssertTrue(message.contains(option), "expected missing option \(option); got \(message)")
            }
        }
    }

    func testValidateToolchainRejectsMissingRequiredMatchesImporterOptions() throws {
        for option in NativeColmapHelpFixture.matchesImporterOptions {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try ToolchainFixtureBuilder.createToolchain(at: root)

            let runner = makeValidationRunner(
                root: root,
                matchesImporterStdout: NativeColmapHelpFixture.matchesImporter
                    .replacingOccurrences(
                        of: "  --\(option) <value>\n",
                        with: ""
                    )
            )

            let manager = ToolchainManager(runner: runner)
            XCTAssertThrowsError(
                try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base]),
                "Expected missing option rejection for \(option)"
            ) { error in
                guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                    return XCTFail("Expected invalidToolchain error for \(option), got \(error)")
                }
                XCTAssertTrue(message.contains(option), "expected missing option \(option); got \(message)")
            }
        }
    }

    func testValidateToolchainRejectsMissingVocabularyRetrieverCommand() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let runner = makeValidationRunner(
            root: root,
            vocabularyExitCode: 2,
            vocabularyStderr: "ERROR: unrecognized command: local_vocab_retriever"
        )

        let manager = ToolchainManager(runner: runner)
        XCTAssertThrowsError(
            try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base])
        ) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error, got \(error)")
            }
            XCTAssertTrue(message.contains("local_vocab_retriever"), "expected missing retriever command; got \(message)")
        }
    }

    func testValidateToolchainRejectsMissingRequiredVocabularyOptions() throws {
        for option in NativeColmapHelpFixture.vocabularyOptions {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try ToolchainFixtureBuilder.createToolchain(at: root)

            let runner = makeValidationRunner(
                root: root,
                vocabularyStdout: NativeColmapHelpFixture.vocabulary.replacingOccurrences(
                    of: "  --\(option) <value>\n",
                    with: ""
                )
            )

            let manager = ToolchainManager(runner: runner)
            XCTAssertThrowsError(
                try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base]),
                "Expected missing option rejection for \(option)"
            ) { error in
                guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                    return XCTFail("Expected invalidToolchain error for \(option), got \(error)")
                }
                XCTAssertTrue(message.contains(option), "expected missing option \(option); got \(message)")
            }
        }
    }

    func testValidateToolchainRejectsPrefixSpoofedColmapOption() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let runner = makeValidationRunner(
            root: root,
            mapperStdout: NativeColmapHelpFixture.mapper.replacingOccurrences(
                of: "--Mapper.random_seed <value>",
                with: "--Mapper.random_seed_extra <value>"
            )
        )

        let manager = ToolchainManager(runner: runner)
        XCTAssertThrowsError(
            try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base])
        ) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error, got \(error)")
            }
            XCTAssertTrue(message.contains("Mapper.random_seed"), "expected exact option rejection; got \(message)")
        }
    }

    func testValidateToolchainRejectsOptionMentionedOnlyInProse() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let misleadingHelp = NativeColmapHelpFixture.mapper.replacingOccurrences(
            of: "  --Mapper.random_seed <value>",
            with: "  Note: --Mapper.random_seed <value> is unavailable"
        )
        let manager = ToolchainManager(
            runner: makeValidationRunner(root: root, mapperStdout: misleadingHelp)
        )

        XCTAssertThrowsError(
            try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base])
        ) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error, got \(error)")
            }
            XCTAssertTrue(message.contains("Mapper.random_seed"), "expected declared-option check; got \(message)")
        }
    }

    func testValidateToolchainRejectsAbnormalColmapProbeTermination() throws {
        let cases: [(String, Process.TerminationReason, Process.TerminationReason, Process.TerminationReason)] = [
            ("root", .uncaughtSignal, .exit, .exit),
            ("mapper", .exit, .uncaughtSignal, .exit),
            ("local_vocab_retriever", .exit, .exit, .uncaughtSignal),
        ]

        for (label, rootTermination, mapperTermination, vocabularyTermination) in cases {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try ToolchainFixtureBuilder.createToolchain(at: root)

            let runner = makeValidationRunner(
                root: root,
                colmapTerminationReason: rootTermination,
                mapperTerminationReason: mapperTermination,
                vocabularyTerminationReason: vocabularyTermination
            )

            let manager = ToolchainManager(runner: runner)
            XCTAssertThrowsError(
                try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base]),
                "Expected abnormal \(label) termination rejection"
            ) { error in
                guard case ToolchainManager.ToolchainError.invalidToolchain = error else {
                    return XCTFail("Expected invalidToolchain error for \(label), got \(error)")
                }
            }
        }
    }

    func testValidateToolchainAcceptsNativeMsplatClosure() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let msplat = root.appendingPathComponent("bin/easysplat-train")

        let runner = makeValidationRunner(root: root)

        let manager = ToolchainManager(runner: runner)
        let toolchain = try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small])
        XCTAssertEqual(toolchain.msplat, msplat)
    }

    func testValidateToolchainRejectsToolchainWhenNativeTrainerIsMissing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root, includeMsplat: false)

        let runner = makeValidationRunner(root: root)

        let manager = ToolchainManager(runner: runner)
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small])) { error in
            guard case ToolchainManager.ToolchainError.missingBinary(let name) = error else {
                return XCTFail("Expected missingBinary error, got \(error)")
            }
            XCTAssertEqual(name, "bin/easysplat-train")
        }
    }

    func testValidateToolchainNormalizesPackagedMsplatExecutableBit() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let msplat = root.appendingPathComponent("bin/easysplat-train")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: msplat.path)

        let runner = makeValidationRunner(root: root)

        let manager = ToolchainManager(runner: runner)
        let toolchain = try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small])
        XCTAssertEqual(toolchain.msplat, msplat)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: msplat.path))
    }

    func testValidateToolchainRejectsBrokenPackagedMsplat() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let runner = makeValidationRunner(root: root, msplatSelfCheckExitCode: 2)

        let manager = ToolchainManager(runner: runner)
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small])) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("easysplat-train self-check failed"), "expected msplat launch failure; got \(message)")
        }
    }

    func testValidateToolchainFailsWhenPackagedMsplatRequiredFilesAreMissing() throws {
        let cases: [(String, String)] = [
            ("bin/easysplat-train", "bin/easysplat-train"),
            ("bin/default.metallib", "bin/default.metallib"),
            ("msplat/build_info.json", "msplat/build_info.json"),
            ("msplat/LICENSE", "msplat/LICENSE")
        ]

        for (relativePath, expectedName) in cases {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try ToolchainFixtureBuilder.createToolchain(at: root)
            try FileManager.default.removeItem(at: root.appendingPathComponent(relativePath))

            let manager = ToolchainManager(runner: makeValidationRunner(root: root))
            XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small]), "Expected missing error for \(relativePath)") { error in
                switch error {
                case ToolchainManager.ToolchainError.missingBinary(let name),
                     ToolchainManager.ToolchainError.missingLibrary(let name):
                    XCTAssertEqual(name, expectedName)
                default:
                    XCTFail("Expected missing file error for \(relativePath), got \(error)")
                }
            }
        }
    }

    func testValidateToolchainRejectsInvalidPackagedMsplatMetadata() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        try "{}\n".write(to: root.appendingPathComponent("msplat/build_info.json"), atomically: true, encoding: .utf8)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small])) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("msplat build_info.json"), "expected msplat metadata failure; got \(message)")
        }
    }

    func testValidateToolchainRejectsUnexpectedMsplatMetadataKeys() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let buildInfo = root.appendingPathComponent("msplat/build_info.json")
        var payload = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: buildInfo)) as? [String: Any]
        )
        payload["source_path"] = "/Users/example/private-checkout"
        try JSONSerialization.data(withJSONObject: payload).write(to: buildInfo, options: .atomic)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small])) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("unexpected keys"), "expected strict metadata failure; got \(message)")
        }
    }

    func testValidateToolchainRequiresPatchProvenance() throws {
        for key in [
            "checkpoint_patch_sha256",
            "exact_raster_patch_sha256",
            "numeric_stability_patch_sha256",
            "metal_safety_patch_sha256",
            "overlay_sha256",
            "raster_test_sha256",
            "isolation_header_sha256",
            "isolation_source_sha256",
            "isolation_runtime_header_sha256",
            "isolation_runtime_source_sha256",
            "isolation_mask_header_sha256",
            "isolation_mask_source_sha256",
            "isolation_lift_source_sha256",
            "isolation_test_sha256",
            "isolation_mask_test_sha256",
            "isolation_patch_sha256",
            "stage_timing_patch_sha256",
            "memory_efficiency_patch_sha256",
            "densification_memory_patch_sha256",
            "row_span_culling_patch_sha256",
            "geometry_adam_fusion_patch_sha256",
            "parallel_radix_scan_patch_sha256",
            "quaternion_stability_patch_sha256",
        ] {
            for mutation in ["missing", "malformed"] {
                let root = try TestFileBuilder.makeTempDir()
                defer { try? FileManager.default.removeItem(at: root) }
                _ = try ToolchainFixtureBuilder.createToolchain(at: root)
                let buildInfo = root.appendingPathComponent("msplat/build_info.json")
                var payload = try XCTUnwrap(
                    try JSONSerialization.jsonObject(with: Data(contentsOf: buildInfo)) as? [String: Any]
                )
                if mutation == "missing" {
                    payload.removeValue(forKey: key)
                } else {
                    payload[key] = "not-a-hash"
                }
                try JSONSerialization.data(withJSONObject: payload).write(
                    to: buildInfo,
                    options: .atomic
                )

                let manager = ToolchainManager(runner: makeValidationRunner(root: root))
                XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small])) { error in
                    guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                        return XCTFail("Expected invalidToolchain error")
                    }
                    XCTAssertTrue(
                        message.contains(key),
                        "Expected \(key) provenance failure for \(mutation), got \(message)"
                    )
                }
            }
        }
    }

    func testValidateToolchainPinsNativeMsplatSourceArtifacts() throws {
        for key in [
            "patch_sha256",
            "exact_raster_patch_sha256",
            "overlay_sha256",
            "raster_test_sha256",
            "isolation_header_sha256",
            "isolation_source_sha256",
            "isolation_runtime_header_sha256",
            "isolation_runtime_source_sha256",
            "isolation_mask_header_sha256",
            "isolation_mask_source_sha256",
            "isolation_lift_source_sha256",
            "isolation_test_sha256",
            "isolation_mask_test_sha256",
            "isolation_patch_sha256",
            "stage_timing_patch_sha256",
            "memory_efficiency_patch_sha256",
            "densification_memory_patch_sha256",
            "row_span_culling_patch_sha256",
            "geometry_adam_fusion_patch_sha256",
            "parallel_radix_scan_patch_sha256",
            "quaternion_stability_patch_sha256",
        ] {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try ToolchainFixtureBuilder.createToolchain(at: root)
            let buildInfo = root.appendingPathComponent("msplat/build_info.json")
            var payload = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: Data(contentsOf: buildInfo))
                    as? [String: Any]
            )
            payload[key] = String(repeating: "0", count: 64)
            try JSONSerialization.data(withJSONObject: payload).write(
                to: buildInfo,
                options: .atomic
            )

            let manager = ToolchainManager(runner: makeValidationRunner(root: root))
            XCTAssertThrowsError(
                try manager.test_validateToolchain(
                    root: root,
                    requiredCapabilities: [.da3Base, .da3Small]
                )
            ) { error in
                guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                    return XCTFail("Expected invalidToolchain error")
                }
                XCTAssertTrue(
                    message.contains(key),
                    "Expected pinned \(key) provenance failure, got \(message)"
                )
            }
        }
    }

    func testValidateToolchainRejectsMsplatPayloadHashMismatch() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let binary = root.appendingPathComponent("bin/easysplat-train")
        try Data("tampered binary\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small])) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("executable_sha256 mismatch"), "expected native payload hash failure; got \(message)")
        }
    }

    func testValidateToolchainAcceptsIsolationModeVersionOneInMsplatSelfCheck() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let output = """
        {"event":"self_check","isolation_mode_version":1,"scene_bounds_status":"ok","schema_version":2,"sequence":1,"status":"ok","version":"1.1.3 (git 106499b)"}

        """

        let manager = ToolchainManager(
            runner: makeValidationRunner(root: root, msplatSelfCheckStdout: output)
        )

        XCTAssertNoThrow(
            try manager.test_validateToolchain(
                root: root,
                requiredCapabilities: [.da3Base, .da3Small]
            )
        )
    }

    func testValidateToolchainRequiresExactIntegerIsolationModeVersionOneInMsplatSelfCheck() throws {
        let invalidValues: [(label: String, field: String)] = [
            ("missing", ""),
            ("zero", #","isolation_mode_version":0"#),
            ("two", #","isolation_mode_version":2"#),
            ("boolean", #","isolation_mode_version":true"#),
            ("string", #","isolation_mode_version":"1""#),
            ("null", #","isolation_mode_version":null"#),
            ("floating one", #","isolation_mode_version":1.0"#),
            ("fractional", #","isolation_mode_version":1.5"#),
        ]

        for invalidValue in invalidValues {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try ToolchainFixtureBuilder.createToolchain(at: root)
            let output = #"{"event":"self_check","scene_bounds_status":"ok","schema_version":2,"sequence":1,"status":"ok","version":"1.1.3 (git 106499b)""#
                + invalidValue.field
                + "}\n"
            let manager = ToolchainManager(
                runner: makeValidationRunner(root: root, msplatSelfCheckStdout: output)
            )

            XCTAssertThrowsError(
                try manager.test_validateToolchain(
                    root: root,
                    requiredCapabilities: [.da3Base, .da3Small]
                ),
                "expected rejection for \(invalidValue.label) isolation_mode_version"
            ) { error in
                guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                    return XCTFail("Expected invalidToolchain error, got \(error)")
                }
                XCTAssertTrue(
                    message.contains("self-check"),
                    "expected self-check failure for \(invalidValue.label), got \(message)"
                )
            }
        }
    }

    func testValidateToolchainRejectsUnexpectedMsplatSelfCheckKeys() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let output = """
        {"event":"self_check","extra":true,"isolation_mode_version":1,"scene_bounds_status":"ok","schema_version":2,"sequence":1,"status":"ok","version":"1.1.3 (git 106499b)"}

        """
        let manager = ToolchainManager(
            runner: makeValidationRunner(root: root, msplatSelfCheckStdout: output)
        )

        XCTAssertThrowsError(
            try manager.test_validateToolchain(
                root: root,
                requiredCapabilities: [.da3Base, .da3Small]
            )
        ) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error, got \(error)")
            }
            XCTAssertTrue(message.contains("self-check"), "expected self-check failure; got \(message)")
        }
    }

    func testValidateToolchainRejectsMalformedMsplatSelfCheckEvents() throws {
        let invalidOutputs = [
            "not json\n",
            "{\"event\":\"self_check\",\"isolation_mode_version\":1,\"schema_version\":2,\"sequence\":1,\"status\":\"ok\",\"version\":\"1.1.3 (git 106499b)\"}\n",
            "{\"event\":\"self_check\",\"isolation_mode_version\":1,\"scene_bounds_status\":\"failed\",\"schema_version\":2,\"sequence\":1,\"status\":\"ok\",\"version\":\"1.1.3 (git 106499b)\"}\n",
            "{\"event\":\"self_check\",\"isolation_mode_version\":1,\"scene_bounds_status\":\"ok\",\"schema_version\":1,\"sequence\":1,\"status\":\"ok\",\"version\":\"1.1.3 (git 106499b)\"}\n",
            "{\"event\":\"self_check\",\"isolation_mode_version\":1,\"scene_bounds_status\":\"ok\",\"schema_version\":2,\"sequence\":1,\"status\":\"ok\",\"version\":\"1.1.3 (git 106499b)\"}\n{\"event\":\"self_check\"}\n",
            "{\"event\":\"self_check\",\"isolation_mode_version\":1,\"scene_bounds_status\":\"ok\",\"schema_version\":2,\"sequence\":2,\"status\":\"ok\",\"version\":\"1.1.3 (git 106499b)\"}\n",
            "{\"event\":\"self_check\",\"isolation_mode_version\":1,\"scene_bounds_status\":\"ok\",\"schema_version\":2,\"sequence\":1,\"status\":\"ok\",\"version\":\"1.1.3\"}\n",
            "{\"event\":\"self_check\",\"isolation_mode_version\":1,\"scene_bounds_status\":\"ok\",\"schema_version\":2,\"sequence\":1,\"status\":\"ok\",\"version\":\"9.9.9\"}\n",
        ]
        for output in invalidOutputs {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try ToolchainFixtureBuilder.createToolchain(at: root)
            let manager = ToolchainManager(runner: makeValidationRunner(root: root, msplatSelfCheckStdout: output))
            XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small]), "expected rejection for \(output)") { error in
                guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                    return XCTFail("Expected invalidToolchain error")
                }
                XCTAssertTrue(message.contains("self-check"), "expected self-check failure; got \(message)")
            }
        }
    }

    func testValidateToolchainRejectsLegacyMsplatFootprints() throws {
        let legacyPaths = [
            "bin/msplat-train",
            "msplat/bin/msplat-train",
            "msplat/python/bin/python3",
            "msplat/core_extension_path.txt",
            "msplat/python/lib/python3.12/site-packages/msplat/_core.so",
        ]
        for relativePath in legacyPaths {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            _ = try ToolchainFixtureBuilder.createToolchain(at: root, includeMsplat: false)
            let legacy = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: legacy.path, contents: Data("legacy".utf8))

            let manager = ToolchainManager(runner: makeValidationRunner(root: root))
            XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small]), "expected legacy rejection for \(relativePath)") { error in
                guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                    return XCTFail("Expected invalidToolchain error, got \(error)")
                }
                XCTAssertTrue(message.contains("legacy msplat"), "expected legacy footprint failure; got \(message)")
            }
        }
    }

    func testValidateToolchainRejectsUnexpectedOrSymlinkedMsplatFiles() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("msplat/unexpected.txt").path,
            contents: Data("unexpected".utf8)
        )
        var manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small])) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("unexpected files"), "expected exact closure failure; got \(message)")
        }

        try FileManager.default.removeItem(at: root.appendingPathComponent("msplat/unexpected.txt"))
        let license = root.appendingPathComponent("msplat/LICENSE")
        let target = root.appendingPathComponent("license-target")
        try "Apache License 2.0\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: license)
        try FileManager.default.createSymbolicLink(at: license, withDestinationURL: target)
        manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small])) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("symbolic link"), "expected symlink rejection; got \(message)")
        }
    }

    func testValidateToolchainRejectsMsplatExecutableSymlinkWithoutChangingTargetMode() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let executable = root.appendingPathComponent("bin/easysplat-train")
        let target = root.appendingPathComponent("outside-native-binary")
        try Data("fixture native msplat executable\n".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        try FileManager.default.removeItem(at: executable)
        try FileManager.default.createSymbolicLink(at: executable, withDestinationURL: target)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small]))
        let permissions = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testValidateToolchainRejectsSymlinkedMsplatAncestorWithoutChangingTargetMode() throws {
        let root = try TestFileBuilder.makeTempDir()
        let externalBin = root.deletingLastPathComponent()
            .appendingPathComponent("external-bin-(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: externalBin)
        }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.moveItem(at: bin, to: externalBin)
        try FileManager.default.createSymbolicLink(at: bin, withDestinationURL: externalBin)
        let target = externalBin.appendingPathComponent("easysplat-train")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small])) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("symbolic link"), "expected ancestor symlink rejection; got (message)")
        }
        let permissions = try XCTUnwrap(
            try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testValidateToolchainRejectsMultiplyLinkedMsplatExecutable() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let executable = root.appendingPathComponent("bin/easysplat-train")
        let externalLink = root.appendingPathComponent("external-native-binary")
        try FileManager.default.linkItem(at: executable, to: externalLink)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small])) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("hard link"), "expected hard-link rejection; got (message)")
        }
    }

    func testValidateToolchainRejectsFifoBuildInfoBeforeReading() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let buildInfo = root.appendingPathComponent("msplat/build_info.json")
        try FileManager.default.removeItem(at: buildInfo)
        XCTAssertEqual(Darwin.mkfifo(buildInfo.path, 0o600), 0)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small])) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("regular file"), "expected FIFO rejection; got (message)")
        }
    }

    func testValidateToolchainRejectsOversizedMsplatBuildInfoBeforeParsing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let buildInfo = root.appendingPathComponent("msplat/build_info.json")
        try Data(repeating: 0x20, count: 65 * 1_024).write(to: buildInfo, options: .atomic)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small])) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("size"), "expected metadata size rejection; got (message)")
        }
    }

    func testValidateToolchainRejectsNonArmNativeMsplat() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root, msplatArch: "Mach-O 64-bit executable x86_64"))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small])) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.lowercased().contains("easysplat-train"), "expected native msplat arch failure; got \(message)")
        }
    }

    /// Regression: `/usr/bin/file <path>` echoes the path in stdout, so without `file -b`
    /// a non-Mach-O file under a path containing "arm64" (e.g. `.build/index-build/arm64-apple-macosx/...`)
    /// could spoof the substring check and pass validation. With `-b` the path is stripped
    /// and only the file's actual description is inspected.
    func testValidateToolchainRejectsNonMachOPython() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        // file -b output for a non-Mach-O file. No "arm64" anywhere in the description.
        let runner = makeValidationRunner(root: root, da3PythonArch: "data")

        let manager = ToolchainManager(runner: runner)
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small])) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("Mach-O"), "expected Mach-O check to be the failure reason; got \(message)")
        }
    }

    /// EasySplat toolchains are intentionally arm64-only. Universal binaries waste
    /// download and install space and can hide an unreviewed x86 dependency closure.
    func testValidateToolchainRejectsUniversalArmPython() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let universal = "Mach-O universal binary with 2 architectures: [x86_64:Mach-O 64-bit executable x86_64] [arm64:Mach-O 64-bit executable arm64]"
        let runner = makeValidationRunner(
            root: root,
            da3PythonArch: universal,
            msplatArch: universal
        )

        let manager = ToolchainManager(runner: runner)
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small])) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.lowercased().contains("arm64-only"), "expected exact architecture failure; got \(message)")
        }
    }

    /// A Rosetta-installed colmap would launch via Rosetta on Apple silicon and pass `-h`,
    /// but downstream tools depending on its output format / dylibs misbehave. Fail early.
    func testValidateToolchainRejectsRosettaColmap() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let runner = makeValidationRunner(root: root, colmapArch: "Mach-O 64-bit executable x86_64")

        let manager = ToolchainManager(runner: runner)
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small])) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.lowercased().contains("colmap"), "expected colmap-specific message; got \(message)")
        }
    }

    func testValidateToolchainFailsWhenDa3AppMissing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(
            at: root,
            includeDa3AppSentinel: false
        )

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base])) { error in
            guard case ToolchainManager.ToolchainError.missingLibrary(let name) = error else {
                return XCTFail("Expected missingLibrary error")
            }
            XCTAssertEqual(name, "da3_mps/app/easysplat_da3_sfm/run.py")
        }
    }

    func testValidateToolchainFailsWhenDa3ModelMissing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(
            at: root,
            includeDa3Model: false
        )

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base])) { error in
            guard case ToolchainManager.ToolchainError.missingLibrary(let name) = error else {
                return XCTFail("Expected missingLibrary error")
            }
            XCTAssertEqual(name, "da3_mps/models/DA3-BASE/model.safetensors")
        }
    }

    func testValidateToolchainFailsWhenDa3ConfigMissing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ToolchainFixtureBuilder.createToolchain(at: root)
        try FileManager.default.removeItem(at: fixture.da3ConfigFile)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base])) { error in
            guard case ToolchainManager.ToolchainError.missingLibrary(let name) = error else {
                return XCTFail("Expected missingLibrary error")
            }
            XCTAssertEqual(name, "da3_mps/models/DA3-BASE/config.json")
        }
    }

    func testValidateToolchainFailsWhenDa3ModelInfoMissing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let info = root.appendingPathComponent("da3_mps/models/DA3-BASE/easysplat_model_info.json")
        try FileManager.default.removeItem(at: info)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base])) { error in
            guard case ToolchainManager.ToolchainError.missingLibrary(let name) = error else {
                return XCTFail("Expected missingLibrary error")
            }
            XCTAssertEqual(name, "da3_mps/models/DA3-BASE/easysplat_model_info.json")
        }
    }

    func testValidateToolchainFailsWhenDa3SmallModelMissing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(
            at: root,
            includeDa3SmallModel: false
        )

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Small])) { error in
            guard case ToolchainManager.ToolchainError.missingLibrary(let name) = error else {
                return XCTFail("Expected missingLibrary error")
            }
            XCTAssertEqual(name, "da3_mps/models/DA3-SMALL/model.safetensors")
        }
    }

    func testValidateToolchainRejectsNonArmDa3Python() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root, da3PythonArch: "Mach-O 64-bit executable x86_64"))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base])) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.lowercased().contains("da3_mps python"), "expected DA3-specific message; got \(message)")
        }
    }

    func testValidateToolchainFailsWhenDa3HelpFails() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root, da3HelpExitCode: 2))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base])) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("da3_mps failed to launch"), "expected DA3 launch failure; got \(message)")
        }
    }

    func testValidateToolchainFailsWhenDa3BuildInfoMissing() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ToolchainFixtureBuilder.createToolchain(at: root)
        try FileManager.default.removeItem(at: fixture.da3BuildInfo)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base])) { error in
            guard case ToolchainManager.ToolchainError.missingLibrary(let name) = error else {
                return XCTFail("Expected missingLibrary error")
            }
            XCTAssertEqual(name, "da3_mps/build_info.json")
        }
    }

    func testValidateToolchainAllowsNativeCoreOnlyColmapWithoutDa3() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("da3_mps", isDirectory: true))

        let runner = makeValidationRunner(root: root)
        let manager = ToolchainManager(runner: runner)

        XCTAssertNoThrow(
            try manager.test_validateToolchain(
                root: root,
                requiredCapabilities: [.core, .colmap, .msplat]
            )
        )
        XCTAssertTrue(runner.calls.contains { $0.1 == ["help"] })
        XCTAssertFalse(runner.calls.contains { $0.1 == ["--self-check"] })
        XCTAssertFalse(runner.calls.contains { $0.0.contains("da3_mps") })
    }

    func testValidateToolchainRejectsMalformedBuildInfo() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = try ToolchainFixtureBuilder.createToolchain(at: root)
        try "[]\n".write(to: fixture.da3BuildInfo, atomically: true, encoding: .utf8)

        let manager = ToolchainManager(runner: makeValidationRunner(root: root))
        XCTAssertThrowsError(try manager.test_validateToolchain(root: root, requiredCapabilities: [.da3Base, .da3Small])) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error")
            }
            XCTAssertTrue(message.contains("da3_mps build_info.json"))
        }
    }

    func testResolveToolchainUsesDevelopmentOverride() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let manager = ToolchainManager(
            runner: makeValidationRunner(root: root),
            appVersion: "9.9.9",
            locator: BundledToolchainLocator(developmentOverrideRoot: root)
        )
        let toolchain = try await manager.resolveToolchain(
            request: ToolchainCapabilityRequest(capabilities: [.da3Base, .da3Small]),
            onProgress: { _, _ in }
        )
        XCTAssertEqual(toolchain.root, root)
        XCTAssertEqual(toolchain.dataRoot, root)
        XCTAssertEqual(toolchain.metallib, root.appendingPathComponent("bin/default.metallib"))
        XCTAssertEqual(toolchain.toolchainIdentity, "local-\(root.lastPathComponent)")
    }

    func testResolveToolchainUsesSplitAppBundleLayout() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let layout = try ToolchainFixtureBuilder.makeAppBundleLayout(
            at: root.appendingPathComponent("Fixture.app", isDirectory: true),
            movingTreeAt: root
        )

        let manager = ToolchainManager(
            runner: makeValidationRunner(root: layout.helpers),
            appVersion: "2.5.0",
            locator: BundledToolchainLocator(bundleURL: layout.bundle)
        )
        let toolchain = try await manager.resolveToolchain(
            request: ToolchainCapabilityRequest(capabilities: [.core, .colmap, .msplat]),
            onProgress: { _, _ in }
        )
        XCTAssertEqual(toolchain.root, layout.helpers)
        XCTAssertEqual(toolchain.dataRoot, layout.data)
        XCTAssertEqual(toolchain.metallib, layout.data.appendingPathComponent("default.metallib"))
        XCTAssertEqual(toolchain.toolchainIdentity, "2.5.0")
    }

    func testResolveToolchainRefusesDa3FromAnAppBundle() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let layout = try ToolchainFixtureBuilder.makeAppBundleLayout(
            at: root.appendingPathComponent("Fixture.app", isDirectory: true),
            movingTreeAt: root
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: layout.helpers.appendingPathComponent("da3_mps").path
            )
        )

        let manager = ToolchainManager(
            runner: makeValidationRunner(root: layout.helpers),
            locator: BundledToolchainLocator(bundleURL: layout.bundle)
        )
        do {
            _ = try await manager.resolveToolchain(
                request: ToolchainCapabilityRequest(capabilities: [.core, .da3Base]),
                onProgress: { _, _ in }
            )
            XCTFail("Expected artifactNotFound")
        } catch ToolchainManager.ToolchainError.artifactNotFound {
        } catch {
            XCTFail("Expected artifactNotFound, got \(error)")
        }
    }

    func testResolveToolchainAllowsDa3FromADevelopmentOverride() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let manager = ToolchainManager(
            runner: makeValidationRunner(root: root),
            locator: BundledToolchainLocator(developmentOverrideRoot: root)
        )
        let toolchain = try await manager.resolveToolchain(
            request: ToolchainCapabilityRequest(capabilities: [.core, .da3Base]),
            onProgress: { _, _ in }
        )
        XCTAssertEqual(toolchain.da3.root, root.appendingPathComponent("da3_mps", isDirectory: true))
    }

    func testResolveToolchainValidatesAKnownCapabilitySetOnce() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)

        let runner = makeValidationRunner(root: root)
        let manager = ToolchainManager(
            runner: runner,
            locator: BundledToolchainLocator(developmentOverrideRoot: root)
        )
        let request = ToolchainCapabilityRequest(capabilities: [.core, .colmap, .msplat])
        _ = try await manager.resolveToolchain(request: request, onProgress: { _, _ in })
        let callsAfterFirst = runner.calls.count
        XCTAssertGreaterThan(callsAfterFirst, 0)

        _ = try await manager.resolveToolchain(request: request, onProgress: { _, _ in })
        XCTAssertEqual(runner.calls.count, callsAfterFirst)
    }

    func testResolveToolchainRejectsAnEmptyCapabilityRequest() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            locator: BundledToolchainLocator(developmentOverrideRoot: root)
        )
        do {
            _ = try await manager.resolveToolchain(
                request: ToolchainCapabilityRequest(capabilities: []),
                onProgress: { _, _ in }
            )
            XCTFail("Expected invalidToolchain")
        } catch ToolchainManager.ToolchainError.invalidToolchain {
        } catch {
            XCTFail("Expected invalidToolchain, got \(error)")
        }
    }

    /// Provenance, msplat, and supply-chain payload live under the data root in a
    /// split layout; evidence has to read each file from the root it came from.
    func testInstalledTreeEvidenceReadsProvenanceFromASplitLayout() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let layout = try ToolchainFixtureBuilder.makeAppBundleLayout(
            at: root.appendingPathComponent("Fixture.app", isDirectory: true),
            movingTreeAt: root
        )

        let evidence = try ToolchainManager().installedTreeEvidence(
            root: layout.helpers,
            dataRoot: layout.data,
            toolchainIdentity: "2.5.0"
        )

        XCTAssertEqual(evidence.toolchainVersion, "2.5.0")
        let recorded = Set(evidence.provenanceRecords.map(\.path))
        XCTAssertTrue(recorded.contains("provenance/colmap.json"))
        XCTAssertTrue(recorded.contains("msplat/build_info.json"))
        XCTAssertTrue(recorded.contains("supply-chain/components.json"))
        XCTAssertNotNil(evidence.installedCriticalFileSHA256["bin/default.metallib"])
        XCTAssertFalse(evidence.nativeTrainerBuildDigest.isEmpty)
    }

    /// A single-root development tree and the split bundle carved out of it hold
    /// identical bytes, so the trainer digest must not depend on the layout.
    func testInstalledTreeEvidenceDigestIsIndependentOfLayout() throws {
        let single = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: single) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: single)
        let singleEvidence = try ToolchainManager().installedTreeEvidence(
            root: single,
            toolchainIdentity: "local-single"
        )

        let split = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: split) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: split)
        let layout = try ToolchainFixtureBuilder.makeAppBundleLayout(
            at: split.appendingPathComponent("Fixture.app", isDirectory: true),
            movingTreeAt: split
        )
        let splitEvidence = try ToolchainManager().installedTreeEvidence(
            root: layout.helpers,
            dataRoot: layout.data,
            toolchainIdentity: "local-split"
        )

        XCTAssertEqual(
            singleEvidence.nativeTrainerBuildDigest,
            splitEvidence.nativeTrainerBuildDigest
        )
    }

    func testLocatorRejectsABundleWithoutTheAppExtension() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let layout = try ToolchainFixtureBuilder.makeAppBundleLayout(
            at: root.appendingPathComponent("Fixture.bundle", isDirectory: true),
            movingTreeAt: root
        )

        XCTAssertThrowsError(
            try BundledToolchainLocator(bundleURL: layout.bundle).locate()
        )
    }

    func testLocatorRejectsAMissingHelpersDirectory() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let layout = try ToolchainFixtureBuilder.makeAppBundleLayout(
            at: root.appendingPathComponent("Fixture.app", isDirectory: true),
            movingTreeAt: root
        )
        try FileManager.default.removeItem(at: layout.helpers)

        XCTAssertThrowsError(
            try BundledToolchainLocator(bundleURL: layout.bundle).locate()
        )
    }

    func testLocatorRejectsAMissingDataDirectory() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let layout = try ToolchainFixtureBuilder.makeAppBundleLayout(
            at: root.appendingPathComponent("Fixture.app", isDirectory: true),
            movingTreeAt: root
        )
        try FileManager.default.removeItem(at: layout.data)

        XCTAssertThrowsError(
            try BundledToolchainLocator(bundleURL: layout.bundle).locate()
        )
    }

    func testLocatorRejectsANonExecutableColmap() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let layout = try ToolchainFixtureBuilder.makeAppBundleLayout(
            at: root.appendingPathComponent("Fixture.app", isDirectory: true),
            movingTreeAt: root
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: layout.helpers.appendingPathComponent("bin/colmap").path
        )

        XCTAssertThrowsError(
            try BundledToolchainLocator(bundleURL: layout.bundle).locate()
        )
    }

    /// The override wins outright, so a bundle that would otherwise be rejected
    /// never gets consulted.
    func testLocatorPrefersTheDevelopmentOverrideOverTheBundle() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = try BundledToolchainLocator(
            bundleURL: root.appendingPathComponent("Missing.app", isDirectory: true),
            developmentOverrideRoot: root
        ).locate()

        XCTAssertEqual(source, .developmentOverride(root: root))
        XCTAssertTrue(source.isDevelopmentOverride)
    }

    private func makeValidationRunner(
        root: URL,
        colmapArch: String = "Mach-O 64-bit executable arm64",
        colmapHelpStdout: String = NativeColmapHelpFixture.root,
        colmapTerminationReason: Process.TerminationReason = .exit,
        da3PythonArch: String = "Mach-O 64-bit executable arm64",
        msplatArch: String = "Mach-O 64-bit executable arm64",
        mapperExitCode: Int32 = 0,
        mapperStdout: String = NativeColmapHelpFixture.mapper,
        mapperStderr: String = "",
        mapperTerminationReason: Process.TerminationReason = .exit,
        matchesImporterExitCode: Int32 = 0,
        matchesImporterStdout: String = NativeColmapHelpFixture.matchesImporter,
        matchesImporterStderr: String = "",
        matchesImporterTerminationReason: Process.TerminationReason = .exit,
        vocabularyExitCode: Int32 = 0,
        vocabularyStdout: String = NativeColmapHelpFixture.vocabulary,
        vocabularyStderr: String = "",
        vocabularyTerminationReason: Process.TerminationReason = .exit,
        da3HelpExitCode: Int32 = 0,
        msplatSelfCheckExitCode: Int32 = 0,
        msplatSelfCheckStdout: String = "{\"event\":\"self_check\",\"isolation_mode_version\":1,\"scene_bounds_status\":\"ok\",\"schema_version\":2,\"sequence\":1,\"status\":\"ok\",\"version\":\"1.1.3 (git 106499b)\"}\n"
    ) -> MockSubprocessRunner {
        MockSubprocessRunner(scripts: [
            .init(path: "/usr/bin/file", argsPrefix: ["-b", root.appendingPathComponent("bin/colmap").path], result: .init(exitCode: 0, terminationReason: .exit, stdout: colmapArch, stderr: ""), onRun: nil),
            .init(path: root.appendingPathComponent("bin/colmap").path, argsPrefix: ["help"], result: .init(exitCode: 0, terminationReason: colmapTerminationReason, stdout: colmapHelpStdout, stderr: ""), onRun: nil),
            .init(path: root.appendingPathComponent("bin/colmap").path, argsPrefix: ["mapper", "-h"], result: .init(exitCode: mapperExitCode, terminationReason: mapperTerminationReason, stdout: mapperStdout, stderr: mapperStderr), onRun: nil),
            .init(path: root.appendingPathComponent("bin/colmap").path, argsPrefix: ["matches_importer", "-h"], result: .init(exitCode: matchesImporterExitCode, terminationReason: matchesImporterTerminationReason, stdout: matchesImporterStdout, stderr: matchesImporterStderr), onRun: nil),
            .init(path: root.appendingPathComponent("bin/colmap").path, argsPrefix: ["local_vocab_retriever", "-h"], result: .init(exitCode: vocabularyExitCode, terminationReason: vocabularyTerminationReason, stdout: vocabularyStdout, stderr: vocabularyStderr), onRun: nil),
            .init(path: "/usr/bin/file", argsPrefix: ["-b", root.appendingPathComponent("da3_mps/python/bin/python3").path], result: .init(exitCode: 0, terminationReason: .exit, stdout: da3PythonArch, stderr: ""), onRun: nil),
            .init(path: root.appendingPathComponent("da3_mps/bin/easysplat_da3_sfm").path, argsPrefix: ["--help"], result: .init(exitCode: da3HelpExitCode, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: "/usr/bin/file", argsPrefix: ["-b", root.appendingPathComponent("bin/easysplat-train").path], result: .init(exitCode: 0, terminationReason: .exit, stdout: msplatArch, stderr: ""), onRun: nil),
            .init(
                path: root.appendingPathComponent("bin/easysplat-train").path,
                argsPrefix: ["--self-check", "--events-fd", "1"],
                result: .init(
                    exitCode: msplatSelfCheckExitCode,
                    terminationReason: .exit,
                    stdout: msplatSelfCheckStdout,
                    stderr: ""
                ),
                onRun: nil
            )
        ])
    }
}

enum NativeColmapHelpFixture {
    static let matchesImporterOptions = [
        "database_path",
        "match_list_path",
        "match_type",
        "FeatureMatching.use_gpu",
        "FeatureMatching.num_threads",
        "FeatureMatching.max_num_matches",
        "SiftMatching.cpu_brute_force_matcher",
        "EasySplat.require_empty_matching_results",
        "TwoViewGeometry.random_seed",
    ]

    static let mapperOptions = [
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
        "Mapper.min_num_matches",
        "Mapper.ba_refine_focal_length",
    ]

    static let vocabularyOptions = [
        "database_path",
        "output_pair_list_path",
        "request_digest",
        "query_stride",
        "query_image_list_path",
        "excluded_pair_list_path",
        "image_group_list_path",
        "image_group_list_digest",
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

    static let root = """
    COLMAP 4.1.1 -- Structure-from-Motion and Multi-View Stereo

    Available commands:
      help
      version
      feature_extractor
      matches_importer
      local_vocab_retriever
      mapper
      point_triangulator
      bundle_adjuster
      model_analyzer
      image_undistorter
      model_converter

    """

    static let mapper = help(command: "mapper", options: mapperOptions)
    static let matchesImporter = help(
        command: "matches_importer",
        options: matchesImporterOptions
    )
    static let vocabulary = help(command: "local_vocab_retriever", options: vocabularyOptions)

    private static func help(command: String, options: [String]) -> String {
        "COLMAP 4.1.1 \(command)\nOptions:\n" +
            options.sorted().map { "  --\($0) <value>" }.joined(separator: "\n") + "\n"
    }
}
