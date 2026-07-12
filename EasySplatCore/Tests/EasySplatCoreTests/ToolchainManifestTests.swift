#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatCore
import CryptoKit

final class ToolchainManifestTests: XCTestCase {
    func testCriticalCoreFileDiscoveryCoversEveryRuntimeCodeClass() {
        let discovered = ToolchainManager.criticalCoreFiles(in: [
            "lib/libceres.2.dylib",
            "da3_mps/vendor/depth_anything_3/api.py",
            "da3_mps/vendor/depth_anything_3/configs/da3-base.yaml",
            "da3_mps/python/bin/torchrun",
            "da3_mps/python/lib/python3.11/site-packages/torch/bin/protoc",
            "da3_mps/python/lib/python3.11/site-packages/native_extension.so",
            "bin/auxiliary-tool",
            "share/LICENSE",
        ])

        XCTAssertTrue(discovered.contains("lib/libceres.2.dylib"))
        XCTAssertTrue(discovered.contains("da3_mps/vendor/depth_anything_3/api.py"))
        XCTAssertTrue(discovered.contains("da3_mps/vendor/depth_anything_3/configs/da3-base.yaml"))
        XCTAssertTrue(discovered.contains("da3_mps/python/bin/torchrun"))
        XCTAssertTrue(discovered.contains("da3_mps/python/lib/python3.11/site-packages/torch/bin/protoc"))
        XCTAssertTrue(discovered.contains("da3_mps/python/lib/python3.11/site-packages/native_extension.so"))
        XCTAssertTrue(discovered.contains("bin/auxiliary-tool"))
        XCTAssertFalse(discovered.contains("share/LICENSE"))
    }

    func testSchemaV2CriticalFileHashesDecodeLegacyExecutableHashesWithoutBreakingSignature() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let legacyJSON = """
        {
          "schemaVersion": 2,
          "toolchainAPI": 2,
          "keyID": "\(ToolchainManifest.keyID(publicKeyBase64: publicKey)!)",
          "version": "2.0.0",
          "publishedAt": "1970-01-01T00:00:00Z",
          "appVersionRange": {"minimum":"0.2.0-beta.1","maximumExclusive":"0.3.0"},
          "components": [{
            "name": "macos-arm64-core",
            "capabilities": ["runtime.core"],
            "url": "https://example.com/core.zip",
            "sha256": "\(String(repeating: "a", count: 64))",
            "sizeBytes": 1,
            "contents": ["bin/colmap"],
            "executableHashes": {"bin/colmap":"\(String(repeating: "b", count: 64))"},
            "dependencies": [],
            "requirement": "required"
          }],
          "signatureEd25519": ""
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var manifest = try decoder.decode(ToolchainManifest.self, from: Data(legacyJSON.utf8))
        manifest.signatureEd25519 = try key.signature(for: manifest.canonicalData()).base64EncodedString()

        XCTAssertEqual(
            manifest.components[0].criticalFileHashes,
            ["bin/colmap": String(repeating: "b", count: 64)]
        )
        XCTAssertEqual(manifest.components[0].executableHashes, manifest.components[0].criticalFileHashes)
        XCTAssertTrue(manifest.verifying(publicKeyBase64: publicKey))
        let canonical = try XCTUnwrap(JSONSerialization.jsonObject(with: manifest.canonicalData()) as? [String: Any])
        let components = try XCTUnwrap(canonical["components"] as? [[String: Any]])
        XCTAssertNotNil(components[0]["executableHashes"])
        XCTAssertNil(components[0]["criticalFileHashes"])
    }

    func testSchemaV2RoundTripUsesComponentsAndPreservesLegacyArtifactDecoding() throws {
        let component = ToolchainManifest.Component(
            name: "macos-arm64-core",
            capabilities: ["runtime.core"],
            url: "https://example.com/core.zip",
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 123,
            contents: ["bin/colmap"],
            executableHashes: ["bin/colmap": String(repeating: "b", count: 64)],
            dependencies: [],
            requirement: .required
        )
        let manifest = ToolchainManifest(
            schemaVersion: 2,
            toolchainAPI: 2,
            keyID: String(repeating: "c", count: 64),
            version: "2.0.0",
            publishedAt: Date(timeIntervalSince1970: 0),
            appVersionRange: .init(minimum: "1.0.0", maximumExclusive: "3.0.0"),
            components: [component],
            signatureEd25519: "signature"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(manifest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNotNil(object["components"])
        XCTAssertNil(object["artifacts"])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ToolchainManifest.self, from: encoded)
        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(decoded.components.first?.capabilities, ["runtime.core"])

        let legacyJSON = """
        {
          "version": "1.2.3",
          "publishedAt": "1970-01-01T00:00:00Z",
          "artifacts": [{
            "name": "macos-arm64",
            "url": "https://example.com/toolchain.zip",
            "sha256": "abc",
            "sizeBytes": 10,
            "contents": ["bin/colmap"]
          }],
          "signatureEd25519": "legacy"
        }
        """
        let legacy = try decoder.decode(ToolchainManifest.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(legacy.schemaVersion, 1)
        XCTAssertEqual(legacy.artifacts.map(\.name), ["macos-arm64"])
    }

    func testSchemaV2SignatureBindsKeyIDAndComponentMetadata() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        var manifest = ToolchainManifest(
            schemaVersion: 2,
            toolchainAPI: 2,
            keyID: ToolchainManifest.keyID(publicKeyBase64: publicKey)!,
            version: "2.0.0",
            publishedAt: Date(timeIntervalSince1970: 0),
            appVersionRange: .init(minimum: "1.0.0", maximumExclusive: "3.0.0"),
            components: [
                .init(
                    name: "geometry-da3-base",
                    capabilities: ["geometry.da3.base"],
                    url: "https://example.com/base.zip",
                    sha256: String(repeating: "a", count: 64),
                    sizeBytes: 42,
                    contents: ["da3_mps/models/DA3-BASE/model.safetensors"],
                    executableHashes: [:],
                    dependencies: ["macos-arm64-core"],
                    requirement: .required
                )
            ],
            signatureEd25519: ""
        )
        manifest.signatureEd25519 = try key.signature(for: manifest.canonicalData()).base64EncodedString()

        XCTAssertTrue(manifest.verifying(publicKeyBase64: publicKey))
        XCTAssertTrue(manifest.hasMatchingKeyID(publicKeyBase64: publicKey))

        manifest.components[0].dependencies = []
        XCTAssertFalse(manifest.verifying(publicKeyBase64: publicKey))
    }

    func testComponentResolutionInstallsRequestedCapabilitiesAndDependenciesOnly() throws {
        let manifest = ToolchainManifest(
            schemaVersion: 2,
            toolchainAPI: 2,
            keyID: String(repeating: "a", count: 64),
            version: "2.0.0",
            publishedAt: Date(),
            appVersionRange: .init(minimum: "1.0.0", maximumExclusive: "3.0.0"),
            components: [
                .init(name: "macos-arm64-core", capabilities: ["runtime.core"], url: "https://example.com/core.zip", sha256: String(repeating: "1", count: 64), sizeBytes: 1, contents: ["bin/colmap"], executableHashes: [:], dependencies: [], requirement: .required),
                .init(name: "geometry-da3-base", capabilities: ["geometry.da3.base"], url: "https://example.com/base.zip", sha256: String(repeating: "2", count: 64), sizeBytes: 1, contents: ["da3_mps/models/DA3-BASE/model.safetensors"], executableHashes: [:], dependencies: ["macos-arm64-core"], requirement: .required),
                .init(name: "geometry-da3-small", capabilities: ["geometry.da3.small"], url: "https://example.com/small.zip", sha256: String(repeating: "3", count: 64), sizeBytes: 1, contents: ["da3_mps/models/DA3-SMALL/model.safetensors"], executableHashes: [:], dependencies: ["macos-arm64-core"], requirement: .optional),
            ],
            signatureEd25519: ""
        )

        XCTAssertEqual(
            try manifest.resolvedComponents(requesting: ["geometry.da3.base"]).map(\.name),
            ["macos-arm64-core", "geometry-da3-base"]
        )
        XCTAssertEqual(
            try manifest.resolvedComponents(requesting: ["geometry.da3.small"]).map(\.name),
            ["macos-arm64-core", "geometry-da3-small"]
        )
    }

    func testManagerAcceptsOnlyTheThreeApprovedSchemaV2ComponentsAndAppRange() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        var manifest = validSchema2Manifest(publicKey: publicKey)
        let manager = ToolchainManager(appVersion: "2.0.0")

        XCTAssertNoThrow(try manager.test_validateSchema2Manifest(manifest, publicKeyBase64: publicKey))

        var executableSuperset = manifest
        let nativeHelper = "da3_mps/python/lib/python3.11/site-packages/foo/native_helper"
        executableSuperset.components[0].contents.append(nativeHelper)
        executableSuperset.components[0].criticalFileHashes[nativeHelper] = String(repeating: "b", count: 64)
        XCTAssertNoThrow(
            try manager.test_validateSchema2Manifest(executableSuperset, publicKeyBase64: publicKey)
        )

        var missingModelHash = manifest
        missingModelHash.components[1].criticalFileHashes.removeValue(
            forKey: "da3_mps/models/DA3-BASE/config.json"
        )
        XCTAssertThrowsError(
            try manager.test_validateSchema2Manifest(missingModelHash, publicKeyBase64: publicKey)
        )

        manifest.components.append(
            .init(
                name: "compatibility-streaming",
                capabilities: ["compatibility.streaming"],
                url: "https://example.com/streaming.zip",
                sha256: String(repeating: "4", count: 64),
                sizeBytes: 1,
                contents: ["streaming.txt"],
                executableHashes: [:],
                dependencies: ["macos-arm64-core"],
                requirement: .optional
            )
        )
        XCTAssertThrowsError(try manager.test_validateSchema2Manifest(manifest, publicKeyBase64: publicKey))
    }

    func testManagerTreatsMaximumAppVersionAsExclusive() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let manifest = validSchema2Manifest(publicKey: publicKey)

        XCTAssertNoThrow(
            try ToolchainManager(appVersion: "2.9.9")
                .test_validateSchema2Manifest(manifest, publicKeyBase64: publicKey)
        )
        XCTAssertThrowsError(
            try ToolchainManager(appVersion: "3.0.0")
                .test_validateSchema2Manifest(manifest, publicKeyBase64: publicKey)
        )
    }

    func testManagerUsesSemVerPrereleasePrecedenceForAppRange() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        var manifest = validSchema2Manifest(publicKey: publicKey)
        manifest.appVersionRange = .init(minimum: "0.2.0", maximumExclusive: "0.3.0")

        XCTAssertThrowsError(
            try ToolchainManager(appVersion: "0.2.0-beta.1")
                .test_validateSchema2Manifest(manifest, publicKeyBase64: publicKey)
        )

        manifest.appVersionRange = .init(minimum: "0.2.0-alpha.1", maximumExclusive: "0.2.0")
        XCTAssertNoThrow(
            try ToolchainManager(appVersion: "0.2.0-beta.1")
                .test_validateSchema2Manifest(manifest, publicKeyBase64: publicKey)
        )
        XCTAssertThrowsError(
            try ToolchainManager(appVersion: "0.2.0")
                .test_validateSchema2Manifest(manifest, publicKeyBase64: publicKey)
        )

        manifest.appVersionRange = .init(
            minimum: "9223372036854775808.0.0",
            maximumExclusive: "9223372036854775810.0.0"
        )
        XCTAssertNoThrow(
            try ToolchainManager(appVersion: "9223372036854775809.0.0")
                .test_validateSchema2Manifest(manifest, publicKeyBase64: publicKey)
        )
    }

    private func validSchema2Manifest(publicKey: String) -> ToolchainManifest {
        let hash = String(repeating: "a", count: 64)
        let coreContents = [
            "bin/colmap",
            "bin/easysplat-train",
            "bin/default.metallib",
            "da3_mps/bin/easysplat_da3_sfm",
            "da3_mps/python/bin/python3",
            "da3_mps/app/easysplat_da3_sfm/run.py",
            "da3_mps/build_info.json",
            "msplat/build_info.json",
            "lib/libceres.2.dylib",
            "da3_mps/vendor/depth_anything_3/api.py",
            "msplat/LICENSE",
        ]
        let coreCriticalFiles = ToolchainManager.criticalCoreFiles(in: coreContents)
        let coreHashes = Dictionary(uniqueKeysWithValues: coreCriticalFiles.map { ($0, hash) })
        let baseFiles = [
            "da3_mps/models/DA3-BASE/config.json",
            "da3_mps/models/DA3-BASE/easysplat_model_info.json",
            "da3_mps/models/DA3-BASE/model.safetensors",
        ]
        let smallFiles = [
            "da3_mps/models/DA3-SMALL/config.json",
            "da3_mps/models/DA3-SMALL/easysplat_model_info.json",
            "da3_mps/models/DA3-SMALL/model.safetensors",
        ]
        return ToolchainManifest(
            schemaVersion: 2,
            toolchainAPI: 2,
            keyID: ToolchainManifest.keyID(publicKeyBase64: publicKey)!,
            version: "2.0.0",
            publishedAt: Date(),
            appVersionRange: .init(minimum: "1.0.0", maximumExclusive: "3.0.0"),
            components: [
                .init(name: "macos-arm64-core", capabilities: ["runtime.core", "geometry.colmap", "geometry.da3.runtime", "training.msplat"], url: "https://example.com/core.zip", sha256: hash, sizeBytes: 1, contents: coreContents, criticalFileHashes: coreHashes, dependencies: [], requirement: .required),
                .init(name: "geometry-da3-base", capabilities: ["geometry.da3.base"], url: "https://example.com/base.zip", sha256: hash, sizeBytes: 1, contents: baseFiles, criticalFileHashes: Dictionary(uniqueKeysWithValues: baseFiles.map { ($0, hash) }), dependencies: ["macos-arm64-core"], requirement: .required),
                .init(name: "geometry-da3-small", capabilities: ["geometry.da3.small"], url: "https://example.com/small.zip", sha256: hash, sizeBytes: 1, contents: smallFiles, criticalFileHashes: Dictionary(uniqueKeysWithValues: smallFiles.map { ($0, hash) }), dependencies: ["macos-arm64-core"], requirement: .optional),
            ],
            signatureEd25519: ""
        )
    }

    func testManifestSignatureVerification() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

        var manifest = ToolchainManifest(
            version: "1.0.0",
            publishedAt: Date(),
            artifacts: [
                .init(name: "macos-arm64", url: "https://example.com/toolchain.zip", sha256: "abc", sizeBytes: 123, contents: ["bin/colmap"])
            ],
            signatureEd25519: ""
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        var signable = manifest
        signable.signatureEd25519 = ""
        let data = try encoder.encode(signable)
        let signature = try key.signature(for: data)
        manifest.signatureEd25519 = Data(signature).base64EncodedString()

        XCTAssertTrue(manifest.verifying(publicKeyBase64: publicKey))
    }

    func testManifestSignatureVerificationMultipleArtifacts() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

        var manifest = ToolchainManifest(
            version: "1.0.0",
            publishedAt: Date(),
            artifacts: [
                .init(name: "macos-arm64-core", url: "https://example.com/core.zip", sha256: "abc", sizeBytes: 123, contents: ["bin/colmap"]),
                .init(name: "macos-arm64-models", url: "https://example.com/models.zip", sha256: "def", sizeBytes: 456, contents: ["da3_mps/models/DA3-BASE/model.safetensors"]),
            ],
            signatureEd25519: ""
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        var signable = manifest
        signable.signatureEd25519 = ""
        let data = try encoder.encode(signable)
        let signature = try key.signature(for: data)
        manifest.signatureEd25519 = Data(signature).base64EncodedString()

        XCTAssertTrue(manifest.verifying(publicKeyBase64: publicKey))
    }

    func testManifestRejectsMissingSignature() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

        let manifest = ToolchainManifest(
            version: "1.0.0",
            publishedAt: Date(),
            artifacts: [
                .init(name: "macos-arm64", url: "https://example.com/toolchain.zip", sha256: "abc", sizeBytes: 123, contents: ["bin/colmap"])
            ],
            signatureEd25519: ""
        )

        XCTAssertFalse(manifest.verifying(publicKeyBase64: publicKey))
    }

    func testManifestRejectsInvalidSignatureBase64() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

        let manifest = ToolchainManifest(
            version: "1.0.0",
            publishedAt: Date(),
            artifacts: [
                .init(name: "macos-arm64", url: "https://example.com/toolchain.zip", sha256: "abc", sizeBytes: 123, contents: ["bin/colmap"])
            ],
            signatureEd25519: "not base64"
        )

        XCTAssertFalse(manifest.verifying(publicKeyBase64: publicKey))
    }

    func testManifestRejectsInvalidPublicKeyBase64() throws {
        let key = Curve25519.Signing.PrivateKey()

        var manifest = ToolchainManifest(
            version: "1.0.0",
            publishedAt: Date(),
            artifacts: [
                .init(name: "macos-arm64", url: "https://example.com/toolchain.zip", sha256: "abc", sizeBytes: 123, contents: ["bin/colmap"])
            ],
            signatureEd25519: ""
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        var signable = manifest
        signable.signatureEd25519 = ""
        let data = try encoder.encode(signable)
        let signature = try key.signature(for: data)
        manifest.signatureEd25519 = Data(signature).base64EncodedString()

        XCTAssertFalse(manifest.verifying(publicKeyBase64: "not base64"))
    }

    func testManifestRejectsTamperedData() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

        var manifest = ToolchainManifest(
            version: "1.0.0",
            publishedAt: Date(),
            artifacts: [
                .init(name: "macos-arm64", url: "https://example.com/toolchain.zip", sha256: "abc", sizeBytes: 123, contents: ["bin/colmap"])
            ],
            signatureEd25519: ""
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601

        var signable = manifest
        signable.signatureEd25519 = ""
        let data = try encoder.encode(signable)
        let signature = try key.signature(for: data)
        manifest.signatureEd25519 = Data(signature).base64EncodedString()
        manifest.version = "1.0.1"

        XCTAssertFalse(manifest.verifying(publicKeyBase64: publicKey))
    }
}
#endif
