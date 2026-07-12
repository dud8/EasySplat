import CryptoKit
import Foundation
import XCTest
@testable import ManifestToolCore

final class ManifestToolCoreTests: XCTestCase {
    func testSchema2BuilderSignsCriticalHashesForEveryReleaseComponent() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let corePaths = ManifestToolDefaults.criticalCoreFiles + [
            "lib/libceres.2.dylib",
            "da3_mps/vendor/depth-anything-3/src/depth_anything_3/api.py",
            "da3_mps/vendor/depth-anything-3/src/depth_anything_3/configs/da3-base.yaml",
            "da3_mps/python/bin/torchrun",
            "da3_mps/python/lib/python3.11/site-packages/torch/bin/protoc",
            "da3_mps/python/lib/python3.11/site-packages/foo/native_helper",
            "da3_mps/python/lib/python3.11/site-packages/native_extension.so",
            "msplat/LICENSE",
        ]
        let coreFiles = Dictionary(uniqueKeysWithValues: corePaths.enumerated().map {
            ($0.element, Data("core-\($0.offset)".utf8))
        })
        let baseFiles = Dictionary(uniqueKeysWithValues: ManifestToolDefaults.da3BaseContents.enumerated().map {
            ($0.element, Data("base-\($0.offset)".utf8))
        })
        let smallFiles = Dictionary(uniqueKeysWithValues: ManifestToolDefaults.da3SmallContents.enumerated().map {
            ($0.element, Data("small-\($0.offset)".utf8))
        })
        let nativeHelper = "da3_mps/python/lib/python3.11/site-packages/foo/native_helper"
        let coreZip = try makeZip(
            named: "core",
            files: coreFiles,
            executablePaths: [nativeHelper],
            in: tempDir
        )
        let baseZip = try makeZip(named: "base", files: baseFiles, in: tempDir)
        let smallZip = try makeZip(named: "small", files: smallFiles, in: tempDir)
        let keypair = ManifestBuilder.generateKeypair()

        var manifest = try ManifestBuilder.build(
            version: "2.0.0",
            publishedAt: Date(timeIntervalSince1970: 0),
            appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
            components: [
                .init(
                    name: "macos-arm64-core",
                    artifactURL: "https://example.com/core.zip",
                    zipURL: coreZip,
                    capabilities: ManifestToolDefaults.coreCapabilities,
                    dependencies: [],
                    requirement: .required,
                    criticalFilePaths: ManifestToolDefaults.criticalCoreFiles
                ),
                .init(
                    name: "geometry-da3-base",
                    artifactURL: "https://example.com/base.zip",
                    zipURL: baseZip,
                    capabilities: ["geometry.da3.base"],
                    dependencies: ["macos-arm64-core"],
                    requirement: .required,
                    criticalFilePaths: ManifestToolDefaults.da3BaseContents
                ),
                .init(
                    name: "geometry-da3-small",
                    artifactURL: "https://example.com/small.zip",
                    zipURL: smallZip,
                    capabilities: ["geometry.da3.small"],
                    dependencies: ["macos-arm64-core"],
                    requirement: .optional,
                    criticalFilePaths: ManifestToolDefaults.da3SmallContents
                ),
            ],
            privateKeyBase64: keypair.privateKeyBase64
        )

        XCTAssertEqual(manifest.schemaVersion, 2)
        XCTAssertEqual(manifest.toolchainAPI, 2)
        XCTAssertEqual(
            manifest.components.map(\.name),
            ["macos-arm64-core", "geometry-da3-base", "geometry-da3-small"]
        )
        XCTAssertEqual(manifest.appVersionRange.minimum, "0.2.0-beta.1")
        XCTAssertEqual(manifest.appVersionRange.maximumExclusive, "0.3.0")
        XCTAssertEqual(manifest.keyID.count, 64)
        XCTAssertEqual(
            Set(manifest.components[0].criticalFileHashes.keys),
            ManifestToolDefaults.criticalCoreFiles(in: Array(coreFiles.keys)).union([nativeHelper])
        )
        XCTAssertEqual(Set(manifest.components[1].criticalFileHashes.keys), Set(baseFiles.keys))
        XCTAssertEqual(Set(manifest.components[2].criticalFileHashes.keys), Set(smallFiles.keys))
        for component in manifest.components {
            XCTAssertTrue(component.criticalFileHashes.values.allSatisfy { $0.count == 64 })
        }
        XCTAssertFalse(manifest.components[0].criticalFileHashes.keys.contains("msplat/LICENSE"))
        XCTAssertNotNil(manifest.components[0].criticalFileHashes["da3_mps/python/bin/torchrun"])
        XCTAssertNotNil(
            manifest.components[0].criticalFileHashes[
                "da3_mps/python/lib/python3.11/site-packages/torch/bin/protoc"
            ]
        )
        XCTAssertNotNil(manifest.components[0].criticalFileHashes[nativeHelper])
        XCTAssertNotNil(
            manifest.components[0].criticalFileHashes[
                "da3_mps/vendor/depth-anything-3/src/depth_anything_3/configs/da3-base.yaml"
            ]
        )
        XCTAssertEqual(
            Set(manifest.components[1].criticalFileHashes.keys),
            Set(manifest.components[1].contents)
        )
        XCTAssertEqual(
            Set(manifest.components[2].criticalFileHashes.keys),
            Set(manifest.components[2].contents)
        )
        XCTAssertTrue(ManifestBuilder.verifySignature(for: manifest, publicKeyBase64: keypair.publicKeyBase64))

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ManifestBuilder.canonicalData(for: manifest)) as? [String: Any]
        )
        let components = try XCTUnwrap(object["components"] as? [[String: Any]])
        XCTAssertTrue(components.allSatisfy { $0["criticalFileHashes"] != nil })
        XCTAssertTrue(components.allSatisfy { $0["executableHashes"] == nil })

        manifest.components[1].criticalFileHashes[ManifestToolDefaults.da3BaseContents[0]] = String(repeating: "0", count: 64)
        XCTAssertFalse(ManifestBuilder.verifySignature(for: manifest, publicKeyBase64: keypair.publicKeyBase64))
    }

    func testSchema2LegacyExecutableHashesDecodeAndPreserveCanonicalSignatureField() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let hash = String(repeating: "a", count: 64)
        let keyID = SHA256.hash(data: key.publicKey.rawRepresentation)
            .map { String(format: "%02x", $0) }
            .joined()
        let json = """
        {
          "schemaVersion": 2,
          "toolchainAPI": 2,
          "keyID": "\(keyID)",
          "version": "2.0.0",
          "publishedAt": "1970-01-01T00:00:00Z",
          "appVersionRange": {"minimum":"0.2.0-beta.1","maximumExclusive":"0.3.0"},
          "components": [{
            "name": "macos-arm64-core",
            "capabilities": ["runtime.core"],
            "url": "https://example.com/core.zip",
            "sha256": "\(hash)",
            "sizeBytes": 1,
            "contents": ["bin/colmap"],
            "executableHashes": {"bin/colmap":"\(hash)"},
            "dependencies": [],
            "requirement": "required"
          }],
          "signatureEd25519": ""
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(ManifestDocument.self, from: Data(json.utf8))
        manifest.signatureEd25519 = try key.signature(
            for: ManifestBuilder.canonicalData(for: manifest)
        ).base64EncodedString()

        XCTAssertEqual(manifest.components[0].criticalFileHashes, ["bin/colmap": hash])
        XCTAssertTrue(ManifestBuilder.verifySignature(for: manifest, publicKeyBase64: publicKey))
        let canonical = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ManifestBuilder.canonicalData(for: manifest)) as? [String: Any]
        )
        let components = try XCTUnwrap(canonical["components"] as? [[String: Any]])
        XCTAssertNotNil(components[0]["executableHashes"])
        XCTAssertNil(components[0]["criticalFileHashes"])
    }

    func testSchema2BuilderRejectsMissingCriticalFile() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let zip = try makeZip(
            named: "incomplete",
            files: ["bin/colmap": Data("colmap".utf8)],
            in: tempDir
        )
        let keypair = ManifestBuilder.generateKeypair()

        XCTAssertThrowsError(
            try ManifestBuilder.build(
                version: "2.0.0",
                publishedAt: Date(timeIntervalSince1970: 0),
                appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
                components: [
                    .init(
                        name: "macos-arm64-core",
                        artifactURL: "https://example.com/core.zip",
                        zipURL: zip,
                        capabilities: ManifestToolDefaults.coreCapabilities,
                        dependencies: [],
                        requirement: .required,
                        criticalFilePaths: ["bin/colmap", "bin/easysplat-train"]
                    )
                ],
                privateKeyBase64: keypair.privateKeyBase64
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("Critical file"))
        }
    }

    func testSchema2BuilderRejectsComponentWithoutCriticalHashContract() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let zip = tempDir.appendingPathComponent("core.zip")
        try Data("not inspected".utf8).write(to: zip)
        let keypair = ManifestBuilder.generateKeypair()
        XCTAssertThrowsError(
            try ManifestBuilder.build(
                version: "2.0.0",
                publishedAt: Date(timeIntervalSince1970: 0),
                appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
                components: [
                    .init(
                        name: "macos-arm64-core",
                        artifactURL: "https://example.com/core.zip",
                        zipURL: zip,
                        capabilities: ManifestToolDefaults.coreCapabilities,
                        dependencies: [],
                        requirement: .required,
                        contents: ["bin/colmap"],
                        criticalFilePaths: [],
                        deriveExactContents: false
                    )
                ],
                privateKeyBase64: keypair.privateKeyBase64
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("critical files"))
        }
    }

    func testSchema2BuilderRejectsComponentAtGitHubAssetLimitBeforeReadingArchive() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let oversized = tempDir.appendingPathComponent("oversized.zip")
        XCTAssertTrue(FileManager.default.createFile(atPath: oversized.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: ManifestBuilder.maximumReleaseAssetBytes)
        try handle.close()

        XCTAssertThrowsError(
            try ManifestBuilder.build(
                version: "2.0.0",
                publishedAt: Date(),
                appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
                components: [
                    .init(
                        name: "macos-arm64-core",
                        artifactURL: "https://example.com/core.zip",
                        zipURL: oversized,
                        capabilities: ManifestToolDefaults.coreCapabilities,
                        dependencies: [],
                        requirement: .required,
                        criticalFilePaths: ManifestToolDefaults.criticalCoreFiles
                    )
                ],
                privateKeyBase64: ManifestBuilder.generateKeypair().privateKeyBase64
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("2 GiB"))
        }
    }

    func testBuildSplitManifestSignsAndVerifies() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let coreZip = tempDir.appendingPathComponent("core.zip")
        let modelsZip = tempDir.appendingPathComponent("models.zip")
        try Data("core".utf8).write(to: coreZip)
        try Data("models".utf8).write(to: modelsZip)

        let keypair = ManifestBuilder.generateKeypair()
        let manifest = try ManifestBuilder.build(
            version: "1.2.3",
            publishedAt: Date(timeIntervalSince1970: 0),
            artifacts: [
                ManifestArtifactInput(
                    name: "macos-arm64-core",
                    artifactURL: "https://example.com/core.zip",
                    zipURL: coreZip,
                    contents: ManifestToolDefaults.splitCoreContents
                ),
                ManifestArtifactInput(
                    name: "macos-arm64-models",
                    artifactURL: "https://example.com/models.zip",
                    zipURL: modelsZip,
                    contents: ManifestToolDefaults.splitModelsContents
                ),
            ],
            privateKeyBase64: keypair.privateKeyBase64
        )

        XCTAssertEqual(manifest.version, "1.2.3")
        XCTAssertEqual(manifest.schemaVersion, 1)
        XCTAssertEqual(manifest.artifacts.count, 2)
        XCTAssertTrue(ManifestBuilder.verifySignature(for: manifest, publicKeyBase64: keypair.publicKeyBase64))
        let canonical = try XCTUnwrap(
            JSONSerialization.jsonObject(with: ManifestBuilder.canonicalData(for: manifest)) as? [String: Any]
        )
        XCTAssertNotNil(canonical["artifacts"])
        XCTAssertNil(canonical["components"])
        XCTAssertNil(canonical["schemaVersion"])
        XCTAssertEqual(manifest.artifacts[0].contents, ManifestToolDefaults.splitCoreContents)
        XCTAssertEqual(manifest.artifacts[1].contents, ManifestToolDefaults.splitModelsContents)
        XCTAssertEqual(ManifestToolDefaults.splitCoreContents, [
            "bin/colmap",
            "bin/easysplat-train",
            "bin/default.metallib",
            "lib/libcrypto.3.dylib",
            "lib/libssl.3.dylib",
            "msplat/build_info.json",
            "msplat/LICENSE",
            "da3_mps/bin/easysplat_da3_sfm",
            "da3_mps/python/bin/python3",
            "da3_mps/build_info.json",
            "da3_mps/app/easysplat_da3_sfm/run.py",
            "da3_mps/vendor/depth-anything-3/src/depth_anything_3/api.py",
        ])
        XCTAssertEqual(ManifestToolDefaults.splitModelsContents, [
            "da3_mps/models/DA3-BASE/config.json",
            "da3_mps/models/DA3-BASE/model.safetensors",
            "da3_mps/models/DA3-BASE/easysplat_model_info.json",
            "da3_mps/models/DA3-SMALL/config.json",
            "da3_mps/models/DA3-SMALL/model.safetensors",
            "da3_mps/models/DA3-SMALL/easysplat_model_info.json",
        ])
    }

    func testBuildMonolithicManifestUsesMonolithicContents() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let zip = tempDir.appendingPathComponent("toolchain.zip")
        try Data("monolithic".utf8).write(to: zip)
        let keypair = ManifestBuilder.generateKeypair()

        let manifest = try ManifestBuilder.build(
            version: "9.9.9",
            publishedAt: Date(timeIntervalSince1970: 123),
            artifacts: [
                ManifestArtifactInput(
                    name: "macos-arm64",
                    artifactURL: "https://example.com/toolchain.zip",
                    zipURL: zip,
                    contents: ManifestToolDefaults.monolithicContents
                )
            ],
            privateKeyBase64: keypair.privateKeyBase64
        )

        XCTAssertEqual(manifest.artifacts.map(\.name), ["macos-arm64"])
        XCTAssertEqual(manifest.artifacts.first?.contents, ManifestToolDefaults.monolithicContents)
    }

    func testBuildRejectsInvalidPrivateKey() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let zip = tempDir.appendingPathComponent("toolchain.zip")
        try Data("toolchain".utf8).write(to: zip)

        XCTAssertThrowsError(
            try ManifestBuilder.build(
                version: "0.1.0",
                publishedAt: Date(),
                artifacts: [
                    ManifestArtifactInput(
                        name: "macos-arm64",
                        artifactURL: "https://example.com/toolchain.zip",
                        zipURL: zip,
                        contents: ManifestToolDefaults.monolithicContents
                    )
                ],
                privateKeyBase64: "not-base64"
            )
        )
    }

    func testArgParserRequireThrowsForMissingValue() {
        var parser = ArgParser(["--version"])
        XCTAssertThrowsError(try parser.require("--version"))
        XCTAssertNil(parser.value(for: "--missing"))
    }

    func testResolvePrivateKeyFromFile() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let keyURL = tempDir.appendingPathComponent("private.txt")
        let keypair = ManifestBuilder.generateKeypair()
        try keypair.privateKeyBase64.write(to: keyURL, atomically: true, encoding: .utf8)

        var parser = ArgParser(["--private-key-file", keyURL.path])
        let resolved = try ManifestKeyInput.resolvePrivateKeyBase64(parser: &parser)

        XCTAssertEqual(resolved, keypair.privateKeyBase64)
    }

    func testResolvePrivateKeyFromEnvironment() async throws {
        let keypair = ManifestBuilder.generateKeypair()
        let restore = await scopedEnvironment(["MANIFEST_PRIVATE_KEY_TEST": keypair.privateKeyBase64])
        defer { restore() }

        var parser = ArgParser(["--private-key-env", "MANIFEST_PRIVATE_KEY_TEST"])
        let resolved = try ManifestKeyInput.resolvePrivateKeyBase64(parser: &parser)

        XCTAssertEqual(resolved, keypair.privateKeyBase64)
    }

    func testResolvePrivateKeyRejectsConflictingSources() throws {
        var parser = ArgParser([
            "--private-key-file", "/tmp/key",
            "--private-key-env", "MANIFEST_PRIVATE_KEY_TEST",
        ])

        XCTAssertThrowsError(try ManifestKeyInput.resolvePrivateKeyBase64(parser: &parser)) { error in
            XCTAssertTrue(error.localizedDescription.contains("exactly one"))
        }
    }

    func testResolvePrivateKeyRejectsInlineArgument() throws {
        var parser = ArgParser(["--private-key", "secret"])

        XCTAssertThrowsError(try ManifestKeyInput.resolvePrivateKeyBase64(parser: &parser)) { error in
            XCTAssertTrue(error.localizedDescription.contains("file or environment"))
        }
    }

    func testResolvePrivateKeyRejectsMissingSource() throws {
        var parser = ArgParser(["--version", "1.0.0"])

        XCTAssertThrowsError(try ManifestKeyInput.resolvePrivateKeyBase64(parser: &parser)) { error in
            XCTAssertTrue(error.localizedDescription.contains("exactly one"))
        }
    }

    func testWritePrivateKeyUsesOwnerOnlyPermissions() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let keyURL = tempDir.appendingPathComponent("private.txt")

        try ManifestKeyInput.writePrivateKeyBase64("secret", to: keyURL)

        let mode = try FileManager.default.attributesOfItem(atPath: keyURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
    }

    private func makeTempDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeZip(
        named name: String,
        files: [String: Data],
        executablePaths: Set<String> = [],
        in root: URL
    ) throws -> URL {
        let source = root.appendingPathComponent("\(name)-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (path, data) in files {
            let destination = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination)
            if executablePaths.contains(path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            }
        }

        let zip = root.appendingPathComponent("\(name).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = source
        process.arguments = ["-q", zip.path] + files.keys.sorted()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw NSError(
                domain: "ManifestToolCoreTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create test archive"]
            )
        }
        return zip
    }
}

private func scopedEnvironment(_ changes: [String: String?]) async -> () -> Void {
    let previous = changes.reduce(into: [String: String?]()) { result, entry in
        result[entry.key] = ProcessInfo.processInfo.environment[entry.key]
    }
    applyEnvironment(changes)
    return {
        applyEnvironment(previous)
    }
}

private func applyEnvironment(_ changes: [String: String?]) {
    for (key, value) in changes {
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }
}
