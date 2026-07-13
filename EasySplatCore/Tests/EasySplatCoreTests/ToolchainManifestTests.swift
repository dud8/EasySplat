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

    func testManifestRejectsExecutableHashesAlias() throws {
        let json = """
        {
          "schemaVersion": 2,
          "toolchainAPI": 2,
          "keyID": "\(String(repeating: "c", count: 64))",
          "version": "2.0.0",
          "publishedAt": "1970-01-01T00:00:00Z",
          "appVersionRange": {"minimum":"0.2.0-beta.1","maximumExclusive":"0.3.0"},
          "components": [{
            "name": "macos-arm64-core",
            "capabilities": ["runtime.core"],
            "url": "https://example.com/core.zip",
            "sha256": "\(String(repeating: "a", count: 64))",
            "sizeBytes": 1,
            "expandedSizeBytes": 2,
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

        XCTAssertThrowsError(
            try decoder.decode(ToolchainManifest.self, from: Data(json.utf8))
        )
    }

    func testManifestRoundTripUsesOnlyV2ComponentFields() throws {
        let component = ToolchainManifest.Component(
            name: "macos-arm64-core",
            capabilities: ["runtime.core"],
            url: "https://example.com/core.zip",
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 123,
            contents: ["bin/colmap"],
            criticalFileHashes: ["bin/colmap": String(repeating: "b", count: 64)],
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
        let components = try XCTUnwrap(object["components"] as? [[String: Any]])
        XCTAssertNotNil(components[0]["criticalFileHashes"])
        XCTAssertNil(components[0]["executableHashes"])

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ToolchainManifest.self, from: encoded)
        XCTAssertEqual(decoded.schemaVersion, 2)
        XCTAssertEqual(decoded.components.first?.capabilities, ["runtime.core"])
    }

    func testManifestRejectsSchema1MonolithicAndSplitArtifacts() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for names in [["macos-arm64"], ["macos-arm64-core", "macos-arm64-models"]] {
            let artifacts = names.map { name in
                """
                {"name":"\(name)","url":"https://example.com/\(name).zip","sha256":"abc","sizeBytes":10,"contents":["bin/colmap"]}
                """
            }.joined(separator: ",")
            let json = """
            {
              "version": "1.2.3",
              "publishedAt": "1970-01-01T00:00:00Z",
              "artifacts": [\(artifacts)],
              "signatureEd25519": "legacy"
            }
            """

            XCTAssertThrowsError(
                try decoder.decode(ToolchainManifest.self, from: Data(json.utf8)),
                "Schema-1 artifact set unexpectedly decoded: \(names)"
            )
        }
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
                    criticalFileHashes: [:],
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
                .init(name: "macos-arm64-core", capabilities: ["runtime.core"], url: "https://example.com/core.zip", sha256: String(repeating: "1", count: 64), sizeBytes: 1, contents: ["bin/colmap"], criticalFileHashes: [:], dependencies: [], requirement: .required),
                .init(name: "geometry-da3-base", capabilities: ["geometry.da3.base"], url: "https://example.com/base.zip", sha256: String(repeating: "2", count: 64), sizeBytes: 1, contents: ["da3_mps/models/DA3-BASE/model.safetensors"], criticalFileHashes: [:], dependencies: ["macos-arm64-core"], requirement: .required),
                .init(name: "geometry-da3-small", capabilities: ["geometry.da3.small"], url: "https://example.com/small.zip", sha256: String(repeating: "3", count: 64), sizeBytes: 1, contents: ["da3_mps/models/DA3-SMALL/model.safetensors"], criticalFileHashes: [:], dependencies: ["macos-arm64-core"], requirement: .optional),
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

        var overlappingContents = manifest
        overlappingContents.components[2].contents.append(
            overlappingContents.components[1].contents[0]
        )
        XCTAssertThrowsError(
            try manager.test_validateSchema2Manifest(overlappingContents, publicKeyBase64: publicKey)
        )

        var caseCollidingContents = manifest
        caseCollidingContents.components[2].contents.append(
            manifest.components[1].contents[0].uppercased()
        )
        XCTAssertThrowsError(
            try manager.test_validateSchema2Manifest(caseCollidingContents, publicKeyBase64: publicKey)
        )

        var unicodeCollidingContents = manifest
        unicodeCollidingContents.components[0].contents.append("licenses/Caf\u{00E9}.txt")
        unicodeCollidingContents.components[2].contents.append("licenses/Cafe\u{0301}.txt")
        XCTAssertThrowsError(
            try manager.test_validateSchema2Manifest(unicodeCollidingContents, publicKeyBase64: publicKey)
        )

        var installerStateCollision = manifest
        installerStateCollision.components[0].contents.append(".EASYSPLAT_TOOLCHAIN_STATE.JSON")
        XCTAssertThrowsError(
            try manager.test_validateSchema2Manifest(installerStateCollision, publicKeyBase64: publicKey)
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
                criticalFileHashes: [:],
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

    func testManagerRejectsNormalPhotoToolchainAboveTwoPointFiveGB() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        var manifest = validSchema2Manifest(publicKey: publicKey)
        let manager = ToolchainManager(appVersion: "2.0.0")

        manifest.components[0].sizeBytes = 1_000_000_000
        manifest.components[1].sizeBytes = 1_000_000_000
        manifest.components[2].sizeBytes = 500_000_000
        XCTAssertNoThrow(try manager.test_validateSchema2Manifest(manifest, publicKeyBase64: publicKey))

        manifest.components[0].sizeBytes += 1
        XCTAssertThrowsError(
            try manager.test_validateSchema2Manifest(manifest, publicKeyBase64: publicKey)
        )

        manifest.components[0].sizeBytes = 2_147_483_648
        manifest.components[1].sizeBytes = 1
        manifest.components[2].sizeBytes = 1
        XCTAssertThrowsError(
            try manager.test_validateSchema2Manifest(manifest, publicKeyBase64: publicKey)
        )
    }

    func testManagerRejectsNonASCIISemanticVersionDigits() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let manifest = validSchema2Manifest(publicKey: publicKey)

        XCTAssertThrowsError(
            try ToolchainManager(appVersion: "٢.0.0")
                .test_validateSchema2Manifest(manifest, publicKeyBase64: publicKey)
        )
    }

    func testManagerRejectsUnsafeToolchainVersions() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        for version in ["../../Documents", "/tmp/2.0.0", "2.0.0/escape", "2.0", "٢.0.0"] {
            var manifest = validSchema2Manifest(publicKey: publicKey)
            manifest.version = version
            XCTAssertThrowsError(
                try ToolchainManager(appVersion: "2.0.0")
                    .test_validateSchema2Manifest(manifest, publicKeyBase64: publicKey),
                version
            )
        }
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
        var manifest = validSchema2Manifest(publicKey: publicKey)
        manifest.signatureEd25519 = try key.signature(for: manifest.canonicalData()).base64EncodedString()

        XCTAssertTrue(manifest.verifying(publicKeyBase64: publicKey))
    }

    func testManifestRejectsMissingSignature() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let manifest = validSchema2Manifest(publicKey: publicKey)

        XCTAssertFalse(manifest.verifying(publicKeyBase64: publicKey))
    }

    func testManifestRejectsInvalidSignatureBase64() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

        var manifest = validSchema2Manifest(publicKey: publicKey)
        manifest.signatureEd25519 = "not base64"

        XCTAssertFalse(manifest.verifying(publicKeyBase64: publicKey))
    }

    func testManifestRejectsInvalidPublicKeyBase64() throws {
        let key = Curve25519.Signing.PrivateKey()

        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        var manifest = validSchema2Manifest(publicKey: publicKey)
        manifest.signatureEd25519 = try key.signature(for: manifest.canonicalData()).base64EncodedString()

        XCTAssertFalse(manifest.verifying(publicKeyBase64: "not base64"))
    }

    func testManifestRejectsTamperedData() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

        var manifest = validSchema2Manifest(publicKey: publicKey)
        manifest.signatureEd25519 = try key.signature(for: manifest.canonicalData()).base64EncodedString()
        manifest.version = "1.0.1"

        XCTAssertFalse(manifest.verifying(publicKeyBase64: publicKey))
    }
}
#endif
