import Foundation
import CryptoKit
import XCTest
@testable import EasySplatCore

final class ToolchainBootstrapTests: XCTestCase {
    func testBootstrapValueCarriesSignedManifestAndBundledCoreArchiveURLs() {
        let manifestURL = URL(fileURLWithPath: "/Applications/EasySplat.app/Contents/Resources/bootstrap-manifest.json")
        let archiveURL = URL(fileURLWithPath: "/Applications/EasySplat.app/Contents/Resources/core.zip")

        let bootstrap = ToolchainBootstrap(manifestURL: manifestURL, coreArchiveURL: archiveURL)

        XCTAssertEqual(bootstrap.manifestURL, manifestURL)
        XCTAssertEqual(bootstrap.coreArchiveURL, archiveURL)
    }

    func testConfiguredBootstrapRejectsMalformedManifestBeforeNetworkUse() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifestURL = root.appendingPathComponent("manifest.json")
        let archiveURL = root.appendingPathComponent("core.zip")
        try Data("not json".utf8).write(to: manifestURL)
        try Data("archive".utf8).write(to: archiveURL)
        let manager = makeManager()

        XCTAssertThrowsError(
            try manager.validateBundledBootstrap(
                .init(manifestURL: manifestURL, coreArchiveURL: archiveURL),
                publicKeyBase64: "invalid"
            )
        ) { error in
            guard case ToolchainManager.ToolchainError.invalidManifest = error else {
                return XCTFail("Expected invalidManifest, got \(error)")
            }
        }
    }

    func testConfiguredBootstrapRejectsSignatureSchemaAPIAppRangeKeyIDAndHTTPDependency() throws {
        enum Mutation: CaseIterable { case signature, schema, api, appRange, keyID, dependencyURL }
        for mutation in Mutation.allCases {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let archive = Data("signed-core-archive".utf8)
            let signed = try signedManifest(archive: archive) { manifest in
                switch mutation {
                case .signature: break
                case .schema: manifest.schemaVersion = 3
                case .api: manifest.toolchainAPI = 3
                case .appRange: manifest.appVersionRange.minimum = "9.0.0"
                case .keyID: manifest.keyID = String(repeating: "f", count: 64)
                case .dependencyURL: manifest.components[1].url = "http://downloads.example.com/base.zip"
                }
            }
            var manifest = signed.manifest
            if mutation == .signature { manifest.signatureEd25519 = "tampered" }
            let manifestURL = root.appendingPathComponent("manifest.json")
            let archiveURL = root.appendingPathComponent("core.zip")
            try encode(manifest).write(to: manifestURL)
            try archive.write(to: archiveURL)

            XCTAssertThrowsError(
                try makeManager().validateBundledBootstrap(
                    .init(manifestURL: manifestURL, coreArchiveURL: archiveURL),
                    publicKeyBase64: signed.publicKey
                ),
                "Mutation should be fatal: \(mutation)"
            )
        }
    }

    func testConfiguredBootstrapRejectsArchiveTamperBeforeExtraction() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = Data("signed-core-archive".utf8)
        let signed = try signedManifest(archive: archive)
        let manifestURL = root.appendingPathComponent("manifest.json")
        let archiveURL = root.appendingPathComponent("core.zip")
        try signed.data.write(to: manifestURL)
        try Data(repeating: 0x78, count: archive.count).write(to: archiveURL)

        XCTAssertThrowsError(
            try makeManager().validateBundledBootstrap(
                .init(manifestURL: manifestURL, coreArchiveURL: archiveURL),
                publicKeyBase64: signed.publicKey
            )
        ) { error in
            guard case ToolchainManager.ToolchainError.hashMismatch = error else {
                return XCTFail("Expected hashMismatch, got \(error)")
            }
        }
    }

    func testRemoteVersionFloorRejectsOlderAndAllowsEqualOrNewer() throws {
        let archive = Data("archive".utf8)
        let signed = try signedManifest(version: "2.0.0", archive: archive)
        let manager = makeManager()
        let core = signed.manifest.components[0]
        let bootstrap = ToolchainManager.ValidatedBootstrap(
            manifest: signed.manifest,
            core: core,
            archiveURL: URL(fileURLWithPath: "/tmp/core.zip"),
            semanticVersion: manager.semanticVersionComponents(from: "2.0.0")!
        )

        var older = signed.manifest
        older.version = "1.9.9"
        XCTAssertThrowsError(try manager.validateRemoteVersionFloor(older, bootstrap: bootstrap))
        var equal = signed.manifest
        equal.version = "2.0.0"
        XCTAssertNoThrow(try manager.validateRemoteVersionFloor(equal, bootstrap: bootstrap))
        var newer = signed.manifest
        newer.version = "2.0.1"
        XCTAssertNoThrow(try manager.validateRemoteVersionFloor(newer, bootstrap: bootstrap))
    }

    func testBundledCoreCannotSatisfyDA3Request() throws {
        let signed = try signedManifest(archive: Data("archive".utf8))
        let manager = makeManager()
        let bootstrap = ToolchainManager.ValidatedBootstrap(
            manifest: signed.manifest,
            core: signed.manifest.components[0],
            archiveURL: URL(fileURLWithPath: "/tmp/core.zip"),
            semanticVersion: manager.semanticVersionComponents(from: signed.manifest.version)!
        )

        XCTAssertTrue(manager.bundledCoreCanSatisfy(.init(capabilities: [.core]), bootstrap: bootstrap))
        XCTAssertFalse(manager.bundledCoreCanSatisfy(.init(capabilities: [.da3Base]), bootstrap: bootstrap))
    }

    private func makeManager() -> ToolchainManager {
        ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            appVersion: "0.2.0-beta.1",
            localToolchainRoot: nil
        )
    }

    private func signedManifest(
        version: String = "2.0.0",
        archive: Data,
        mutate: (inout ToolchainManifest) -> Void = { _ in }
    ) throws -> (manifest: ToolchainManifest, publicKey: String, data: Data) {
        let hash: (Data) -> String = {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        }
        let dummyHash = String(repeating: "a", count: 64)
        let core = [
            "bin/colmap", "bin/easysplat-train", "bin/default.metallib", "lib/libomp.dylib",
            "msplat/build_info.json", "msplat/LICENSE", "provenance/colmap.json",
            "provenance/colmap-support.json", "provenance/ceres.json", "provenance/openimageio.json",
            "licenses/COLMAP/COPYING.txt", "licenses/COLMAPSupport/OpenMP-LICENSE.txt",
            "licenses/Ceres/LICENSE", "licenses/OpenImageIO/LICENSE.md", "supply-chain/components.json",
        ]
        let base = [
            "da3_mps/bin/easysplat_da3_sfm", "da3_mps/python/bin/python3",
            "da3_mps/app/easysplat_da3_sfm/run.py",
            "da3_mps/vendor/depth-anything-3/src/depth_anything_3/api.py", "da3_mps/build_info.json",
            "da3_mps/models/DA3-BASE/config.json", "da3_mps/models/DA3-BASE/easysplat_model_info.json",
            "da3_mps/models/DA3-BASE/model.safetensors", "da3_mps/models/DA3-BASE/LICENSE",
        ]
        let small = [
            "da3_mps/models/DA3-SMALL/config.json", "da3_mps/models/DA3-SMALL/easysplat_model_info.json",
            "da3_mps/models/DA3-SMALL/model.safetensors", "da3_mps/models/DA3-SMALL/LICENSE",
        ]
        func hashes(_ paths: [String]) -> [String: String] {
            Dictionary(uniqueKeysWithValues: paths.map { ($0, dummyHash) })
        }
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        var manifest = ToolchainManifest(
            schemaVersion: 2,
            toolchainAPI: 2,
            keyID: ToolchainManifest.keyID(publicKeyBase64: publicKey)!,
            version: version,
            publishedAt: Date(timeIntervalSince1970: 0),
            appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
            components: [
                .init(name: "macos-arm64-core", capabilities: Array(ToolchainManager.coreCapabilities), url: "https://downloads.example.com/core.zip", sha256: hash(archive), sizeBytes: UInt64(archive.count), contents: core, criticalFileHashes: hashes(core), dependencies: [], requirement: .required),
                .init(name: "geometry-da3-base", capabilities: [ToolchainCapability.da3Runtime.rawValue, ToolchainCapability.da3Base.rawValue], url: "https://downloads.example.com/base.zip", sha256: dummyHash, sizeBytes: 1, contents: base, criticalFileHashes: hashes(base), dependencies: ["macos-arm64-core"], requirement: .optional),
                .init(name: "geometry-da3-small", capabilities: [ToolchainCapability.da3Small.rawValue], url: "https://downloads.example.com/small.zip", sha256: dummyHash, sizeBytes: 1, contents: small, criticalFileHashes: hashes(small), dependencies: ["geometry-da3-base"], requirement: .optional),
            ],
            signatureEd25519: ""
        )
        mutate(&manifest)
        manifest.signatureEd25519 = try key.signature(for: manifest.canonicalData()).base64EncodedString()
        return (manifest, publicKey, try encode(manifest))
    }

    private func encode(_ manifest: ToolchainManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(manifest)
    }
}
