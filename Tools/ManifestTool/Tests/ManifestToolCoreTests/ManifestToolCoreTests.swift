import Foundation
import XCTest
@testable import ManifestToolCore

final class ManifestToolCoreTests: XCTestCase {
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
        XCTAssertEqual(manifest.artifacts.count, 2)
        XCTAssertTrue(ManifestBuilder.verifySignature(for: manifest, publicKeyBase64: keypair.publicKeyBase64))
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
        var parser = ArgParser(["--private-key", "abc", "--private-key-file", "/tmp/key"])

        XCTAssertThrowsError(try ManifestKeyInput.resolvePrivateKeyBase64(parser: &parser)) { error in
            XCTAssertTrue(error.localizedDescription.contains("exactly one"))
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
