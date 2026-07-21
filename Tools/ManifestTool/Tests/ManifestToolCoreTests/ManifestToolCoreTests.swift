import CryptoKit
import Foundation
import XCTest
@testable import ManifestToolCore

final class ManifestToolCoreTests: XCTestCase {
    func testBuilderRejectsUnsignedDirectoryEntries() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let source = tempDir.appendingPathComponent("directory-entry-source", isDirectory: true)
        let unsignedDirectory = source.appendingPathComponent("unsigned", isDirectory: true)
        try FileManager.default.createDirectory(at: unsignedDirectory, withIntermediateDirectories: true)
        let payload = source.appendingPathComponent("payload.txt")
        try Data("payload".utf8).write(to: payload)
        let archive = tempDir.appendingPathComponent("directory-entry.zip")
        try runZip(["-q", archive.path, "payload.txt", "unsigned/"], in: source)

        XCTAssertThrowsError(try ManifestBuilder.build(
            version: "2.0.0",
            publishedAt: Date(timeIntervalSince1970: 0),
            appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
            components: [
                .init(
                    name: "fixture",
                    artifactURL: "https://example.com/fixture.zip",
                    zipURL: archive,
                    capabilities: ["fixture"],
                    dependencies: [],
                    requirement: .required,
                    criticalFilePaths: ["payload.txt"]
                )
            ],
            privateKeyBase64: ManifestBuilder.generateKeypair().privateKeyBase64
        ))
    }

    func testBuilderRejectsRepeatedSeparatorArchiveAliases() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let archive = try makeZip(
            named: "repeated-separator",
            files: ["a/xb": Data("payload".utf8)],
            in: tempDir
        )
        var bytes = try Data(contentsOf: archive)
        let original = Data("a/xb".utf8)
        let alias = Data("a//b".utf8)
        var replacements = 0
        while let range = bytes.range(of: original) {
            bytes.replaceSubrange(range, with: alias)
            replacements += 1
        }
        XCTAssertEqual(replacements, 2)
        try bytes.write(to: archive)

        XCTAssertThrowsError(try ManifestBuilder.build(
            version: "2.0.0",
            publishedAt: Date(timeIntervalSince1970: 0),
            appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
            components: [
                .init(
                    name: "fixture",
                    artifactURL: "https://example.com/fixture.zip",
                    zipURL: archive,
                    capabilities: ["fixture"],
                    dependencies: [],
                    requirement: .required,
                    criticalFilePaths: ["a//b"]
                )
            ],
            privateKeyBase64: ManifestBuilder.generateKeypair().privateKeyBase64
        ))
    }

    func testWriteManifestRejectsOversizedAllowedLicenseClosure() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let suffix = String(repeating: "x", count: 96)
        let contents = (0..<80_000).map { "licenses/\($0)-\(suffix).txt" }
        let hashes = Dictionary(uniqueKeysWithValues: contents.map {
            ($0, String(repeating: "a", count: 64))
        })
        let manifest = ManifestDocument(
            keyID: String(repeating: "b", count: 64),
            version: "2.0.0",
            publishedAt: Date(timeIntervalSince1970: 0),
            appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
            components: [
                .init(
                    name: "macos-arm64-core",
                    capabilities: ManifestToolDefaults.coreCapabilities,
                    url: "https://example.com/core.zip",
                    sha256: String(repeating: "c", count: 64),
                    sizeBytes: 1,
                    expandedSizeBytes: 1,
                    expandedClosureSHA256: String(repeating: "d", count: 64),
                    contents: contents,
                    criticalFileHashes: hashes,
                    dependencies: [],
                    requirement: .required
                )
            ],
            signatureEd25519: Data(repeating: 0, count: 64).base64EncodedString()
        )
        let output = tempDir.appendingPathComponent("manifest.json")

        XCTAssertThrowsError(try ManifestBuilder.writeManifest(manifest, to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testBuildAndPrepareReleaseRejectEncodedManifestAboveApplicationLimit() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let archive = try makeZip(
            named: "oversized-manifest",
            files: ["payload.txt": Data("payload".utf8)],
            in: tempDir
        )
        let suffix = String(repeating: "x", count: 256)
        let oversizedCapabilities = (0..<70_000).map { "capability.\($0).\(suffix)" }
        let input = ManifestArtifactInput(
            name: "fixture",
            artifactURL: "https://example.com/fixture.zip",
            zipURL: archive,
            capabilities: oversizedCapabilities,
            dependencies: [],
            requirement: .required,
            criticalFilePaths: ["payload.txt"]
        )
        let keypair = ManifestBuilder.generateKeypair()

        XCTAssertThrowsError(try ManifestBuilder.build(
            version: "2.0.0",
            publishedAt: Date(timeIntervalSince1970: 0),
            appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
            components: [input],
            privateKeyBase64: keypair.privateKeyBase64
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("8 MiB"))
        }

        XCTAssertThrowsError(try ManifestBuilder.prepareRelease(
            repository: "dud8/EasySplat",
            sourceCommit: String(repeating: "a", count: 40),
            version: "2.0.0",
            publishedAt: Date(timeIntervalSince1970: 0),
            appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
            publicKeyBase64: keypair.publicKeyBase64,
            components: [input]
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("8 MiB"))
        }
    }

    func testProductionComponentDefaultsSplitNativeCoreFromOptionalDA3Runtime() {
        XCTAssertEqual(
            ManifestToolDefaults.coreCapabilities,
            ["runtime.core", "geometry.colmap", "training.msplat"]
        )
        XCTAssertFalse(ManifestToolDefaults.criticalCoreFiles.contains { $0.hasPrefix("da3_mps/") })

        let baseRuntime = ManifestToolDefaults.da3BaseContents + [
            "da3_mps/python/lib/python3.13/site-packages/torch/_C.so",
            "da3_mps/vendor/depth-anything-3/src/depth_anything_3/api.py",
        ]
        XCTAssertEqual(
            ManifestToolDefaults.criticalDa3BaseFiles(in: baseRuntime),
            Set(baseRuntime)
        )
    }

    func testSchema2BuilderRejectsCrossComponentAndInstallerStateCollisions() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let firstZip = try makeZip(
            named: "ownership-first",
            files: ["share/Caf\u{00E9}.txt": Data("first".utf8)],
            in: tempDir
        )
        let secondZip = try makeZip(
            named: "ownership-second",
            files: ["share/cafe\u{0301}.TXT": Data("second".utf8)],
            in: tempDir
        )
        let keypair = ManifestBuilder.generateKeypair()

        XCTAssertThrowsError(try ManifestBuilder.build(
            version: "2.0.0",
            publishedAt: Date(timeIntervalSince1970: 0),
            appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
            components: [
                .init(
                    name: "first",
                    artifactURL: "https://example.com/first.zip",
                    zipURL: firstZip,
                    capabilities: ["first"],
                    dependencies: [],
                    requirement: .required,
                    criticalFilePaths: ["share/Caf\u{00E9}.txt"]
                ),
                .init(
                    name: "second",
                    artifactURL: "https://example.com/second.zip",
                    zipURL: secondZip,
                    capabilities: ["second"],
                    dependencies: [],
                    requirement: .optional,
                    criticalFilePaths: ["share/cafe\u{0301}.TXT"]
                ),
            ],
            privateKeyBase64: keypair.privateKeyBase64
        ))

        let stateZip = try makeZip(
            named: "ownership-state",
            files: [".EASYSPLAT_TOOLCHAIN_STATE.JSON": Data("state".utf8)],
            in: tempDir
        )
        XCTAssertThrowsError(try ManifestBuilder.build(
            version: "2.0.0",
            publishedAt: Date(timeIntervalSince1970: 0),
            appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
            components: [
                .init(
                    name: "state",
                    artifactURL: "https://example.com/state.zip",
                    zipURL: stateZip,
                    capabilities: ["state"],
                    dependencies: [],
                    requirement: .required,
                    criticalFilePaths: [".EASYSPLAT_TOOLCHAIN_STATE.JSON"]
                ),
            ],
            privateKeyBase64: keypair.privateKeyBase64
        ))
    }

    func testReleaseVerifierRejectsSignedOwnershipCollisionsBeforeArchiveChecks() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let firstZip = try makeZip(
            named: "verify-first",
            files: ["first.txt": Data("first".utf8)],
            in: tempDir
        )
        let secondZip = try makeZip(
            named: "verify-second",
            files: ["second.txt": Data("second".utf8)],
            in: tempDir
        )
        let urls = [
            "first": "https://example.com/first.zip",
            "second": "https://example.com/second.zip",
        ]
        let archives = ["first": firstZip, "second": secondZip]
        let keypair = ManifestBuilder.generateKeypair()
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: XCTUnwrap(Data(base64Encoded: keypair.privateKeyBase64))
        )
        let original = try ManifestBuilder.build(
            version: "2.0.0",
            publishedAt: Date(timeIntervalSince1970: 0),
            appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
            components: [
                .init(
                    name: "first",
                    artifactURL: urls["first"]!,
                    zipURL: firstZip,
                    capabilities: ["first"],
                    dependencies: [],
                    requirement: .required,
                    criticalFilePaths: ["first.txt"]
                ),
                .init(
                    name: "second",
                    artifactURL: urls["second"]!,
                    zipURL: secondZip,
                    capabilities: ["second"],
                    dependencies: [],
                    requirement: .optional,
                    criticalFilePaths: ["second.txt"]
                ),
            ],
            privateKeyBase64: keypair.privateKeyBase64
        )

        func resigned(_ mutation: (inout ManifestDocument) -> Void) throws -> ManifestDocument {
            var manifest = original
            mutation(&manifest)
            manifest.signatureEd25519 = try privateKey.signature(
                for: ManifestBuilder.canonicalData(for: manifest)
            ).base64EncodedString()
            return manifest
        }

        let overlap = try resigned { manifest in
            manifest.components[1].contents[0] = "FIRST.TXT"
        }
        XCTAssertThrowsError(try ManifestBuilder.verifyRelease(
            manifest: overlap,
            publicKeyBase64: keypair.publicKeyBase64,
            expectedToolchainVersion: "2.0.0",
            expectedAppVersion: "0.2.0-beta.1",
            expectedComponentURLs: urls,
            componentArchives: archives
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("ownership"))
        }

        let stateCollision = try resigned { manifest in
            manifest.components[0].contents[0] = ".EASYSPLAT_TOOLCHAIN_STATE.JSON"
        }
        XCTAssertThrowsError(try ManifestBuilder.verifyRelease(
            manifest: stateCollision,
            publicKeyBase64: keypair.publicKeyBase64,
            expectedToolchainVersion: "2.0.0",
            expectedAppVersion: "0.2.0-beta.1",
            expectedComponentURLs: urls,
            componentArchives: archives
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("ownership"))
        }
    }

    func testReleaseVerifierAuthenticatesManifestURLsAndArchives() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let files = try ProductionToolchainFileFixture()
        let coreZip = try makeZip(
            named: "core",
            files: files.core,
            in: tempDir
        )
        let baseZip = try makeZip(
            named: "base",
            files: files.base,
            in: tempDir
        )
        let smallZip = try makeZip(
            named: "small",
            files: files.small,
            in: tempDir
        )
        let urls = [
            "macos-arm64-core": "https://example.com/core.zip",
            "geometry-da3-base": "https://example.com/base.zip",
            "geometry-da3-small": "https://example.com/small.zip",
        ]
        let keypair = ManifestBuilder.generateKeypair()
        let manifest = try files.withReviewedSourceSnapshot {
            try ManifestBuilder.build(
                version: "2.0.0",
                publishedAt: Date(timeIntervalSince1970: 0),
                appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
                components: [
                    .init(name: "macos-arm64-core", artifactURL: urls["macos-arm64-core"]!, zipURL: coreZip, capabilities: ManifestToolDefaults.coreCapabilities, dependencies: [], requirement: .required, criticalFilePaths: ManifestToolDefaults.criticalCoreFiles),
                    .init(name: "geometry-da3-base", artifactURL: urls["geometry-da3-base"]!, zipURL: baseZip, capabilities: ["geometry.da3.runtime", "geometry.da3.base"], dependencies: ["macos-arm64-core"], requirement: .optional, criticalFilePaths: ManifestToolDefaults.da3BaseContents),
                    .init(name: "geometry-da3-small", artifactURL: urls["geometry-da3-small"]!, zipURL: smallZip, capabilities: ["geometry.da3.small"], dependencies: ["geometry-da3-base"], requirement: .optional, criticalFilePaths: ManifestToolDefaults.da3SmallContents),
                ],
                privateKeyBase64: keypair.privateKeyBase64
            )
        }

        XCTAssertNoThrow(try ManifestBuilder.verifyRelease(
            manifest: manifest,
            publicKeyBase64: keypair.publicKeyBase64,
            expectedToolchainVersion: "2.0.0",
            expectedAppVersion: "0.2.1",
            expectedComponentURLs: urls,
            componentArchives: [
                "macos-arm64-core": coreZip,
                "geometry-da3-base": baseZip,
                "geometry-da3-small": smallZip,
            ]
        ))

        var wrongURLs = urls
        wrongURLs["geometry-da3-base"] = "https://attacker.example/base.zip"
        XCTAssertThrowsError(try ManifestBuilder.verifyRelease(
            manifest: manifest,
            publicKeyBase64: keypair.publicKeyBase64,
            expectedToolchainVersion: "2.0.0",
            expectedAppVersion: "0.2.0-beta.1",
            expectedComponentURLs: wrongURLs,
            componentArchives: [
                "macos-arm64-core": coreZip,
                "geometry-da3-base": baseZip,
                "geometry-da3-small": smallZip,
            ]
        ))

        XCTAssertThrowsError(try ManifestBuilder.verifyRelease(
            manifest: manifest,
            publicKeyBase64: keypair.publicKeyBase64,
            expectedToolchainVersion: "2.0.0",
            expectedAppVersion: "0.3.0",
            expectedComponentURLs: urls,
            componentArchives: [
                "macos-arm64-core": coreZip,
                "geometry-da3-base": baseZip,
                "geometry-da3-small": smallZip,
            ]
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("compatibility range"))
        }
    }

    func testSchema2BuilderRejectsInvalidOrEmptyAppVersionRanges() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let zip = try makeZip(
            named: "core",
            files: ["bin/colmap": Data("colmap".utf8)],
            in: tempDir
        )
        let input = ManifestArtifactInput(
            name: "macos-arm64-core",
            artifactURL: "https://example.com/core.zip",
            zipURL: zip,
            capabilities: ManifestToolDefaults.coreCapabilities,
            dependencies: [],
            requirement: .required,
            criticalFilePaths: ["bin/colmap"]
        )
        let key = ManifestBuilder.generateKeypair().privateKeyBase64

        for range in [
            ManifestDocument.AppVersionRange(minimum: "0.2", maximumExclusive: "0.3.0"),
            ManifestDocument.AppVersionRange(minimum: "0.2.0", maximumExclusive: "0.2.0"),
            ManifestDocument.AppVersionRange(minimum: "0.3.0", maximumExclusive: "0.2.0"),
            ManifestDocument.AppVersionRange(minimum: "0.2.0-01", maximumExclusive: "0.3.0"),
            ManifestDocument.AppVersionRange(minimum: "٠.2.0", maximumExclusive: "0.3.0"),
        ] {
            XCTAssertThrowsError(try ManifestBuilder.build(
                version: "2.0.0",
                publishedAt: Date(timeIntervalSince1970: 0),
                appVersionRange: range,
                components: [input],
                privateKeyBase64: key
            )) { error in
                XCTAssertTrue(error.localizedDescription.contains("version range"))
            }
        }
    }

    func testManifestBuildersRejectUnsafeToolchainVersions() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let zip = try makeZip(
            named: "core",
            files: ["bin/colmap": Data("colmap".utf8)],
            in: tempDir
        )
        let key = ManifestBuilder.generateKeypair().privateKeyBase64
        let input = ManifestArtifactInput(
            name: "macos-arm64-core",
            artifactURL: "https://example.com/core.zip",
            zipURL: zip,
            capabilities: ManifestToolDefaults.coreCapabilities,
            dependencies: [],
            requirement: .required,
            criticalFilePaths: ["bin/colmap"]
        )

        for version in ["../../Documents", "/tmp/2.0.0", "2.0.0/escape", "2.0", "٢.0.0"] {
            XCTAssertThrowsError(try ManifestBuilder.build(
                version: version,
                publishedAt: Date(timeIntervalSince1970: 0),
                appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
                components: [input],
                privateKeyBase64: key
            ))
        }
    }

    func testSchema2BuilderSignsCriticalHashesForEveryReleaseComponent() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var files = try ProductionToolchainFileFixture()
        let extraBasePaths = [
            "da3_mps/vendor/depth-anything-3/src/depth_anything_3/configs/da3-base.yaml",
            "da3_mps/bin/torchrun",
            "da3_mps/app/easysplat_da3_sfm/native_helper",
            "da3_mps/vendor/depth-anything-3/src/depth_anything_3/native_extension.so",
            "da3_mps/licenses/generated-runtime-note.txt",
        ]
        for (offset, path) in extraBasePaths.enumerated() {
            files.base[path] = Data("extra-base-\(offset)".utf8)
        }
        try files.refreshSupplyChain()
        let coreFiles = files.core
        let baseFiles = files.base
        let smallFiles = files.small
        let nativeHelper = "da3_mps/app/easysplat_da3_sfm/native_helper"
        let coreZip = try makeZip(
            named: "core",
            files: coreFiles,
            in: tempDir
        )
        let baseZip = try makeZip(
            named: "base",
            files: baseFiles,
            executablePaths: [nativeHelper],
            in: tempDir
        )
        let smallZip = try makeZip(named: "small", files: smallFiles, in: tempDir)
        let keypair = ManifestBuilder.generateKeypair()

        var manifest = try files.withReviewedSourceSnapshot {
            try ManifestBuilder.build(
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
                    capabilities: ["geometry.da3.runtime", "geometry.da3.base"],
                    dependencies: ["macos-arm64-core"],
                    requirement: .optional,
                    criticalFilePaths: ManifestToolDefaults.da3BaseContents
                ),
                .init(
                    name: "geometry-da3-small",
                    artifactURL: "https://example.com/small.zip",
                    zipURL: smallZip,
                    capabilities: ["geometry.da3.small"],
                    dependencies: ["geometry-da3-base"],
                    requirement: .optional,
                    criticalFilePaths: ManifestToolDefaults.da3SmallContents
                ),
                ],
                privateKeyBase64: keypair.privateKeyBase64
            )
        }

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
            ManifestToolDefaults.criticalCoreFiles(in: Array(coreFiles.keys))
        )
        XCTAssertEqual(Set(manifest.components[1].criticalFileHashes.keys), Set(baseFiles.keys))
        XCTAssertEqual(Set(manifest.components[2].criticalFileHashes.keys), Set(smallFiles.keys))
        XCTAssertEqual(
            manifest.components[0].expandedSizeBytes,
            UInt64(coreFiles.values.reduce(0) { $0 + $1.count })
        )
        XCTAssertEqual(
            manifest.components[1].expandedSizeBytes,
            UInt64(baseFiles.values.reduce(0) { $0 + $1.count })
        )
        XCTAssertEqual(
            manifest.components[2].expandedSizeBytes,
            UInt64(smallFiles.values.reduce(0) { $0 + $1.count })
        )
        for component in manifest.components {
            XCTAssertTrue(component.criticalFileHashes.values.allSatisfy { $0.count == 64 })
        }
        XCTAssertNotNil(manifest.components[0].criticalFileHashes["msplat/LICENSE"])
        XCTAssertNotNil(manifest.components[1].criticalFileHashes["da3_mps/bin/torchrun"])
        XCTAssertNotNil(
            manifest.components[1].criticalFileHashes[
                "da3_mps/vendor/depth-anything-3/src/depth_anything_3/native_extension.so"
            ]
        )
        XCTAssertNotNil(manifest.components[1].criticalFileHashes[nativeHelper])
        XCTAssertNotNil(
            manifest.components[1].criticalFileHashes[
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
        XCTAssertTrue(components.allSatisfy { $0["expandedSizeBytes"] != nil })
        XCTAssertTrue(components.allSatisfy {
            (($0["expandedClosureSHA256"] as? String)?.count ?? 0) == 64
        })

        var expandedSizeTamper = manifest
        expandedSizeTamper.components[1].expandedSizeBytes += 1
        XCTAssertFalse(ManifestBuilder.verifySignature(
            for: expandedSizeTamper,
            publicKeyBase64: keypair.publicKeyBase64
        ))

        manifest.components[1].criticalFileHashes[ManifestToolDefaults.da3BaseContents[0]] = String(repeating: "0", count: 64)
        XCTAssertFalse(ManifestBuilder.verifySignature(for: manifest, publicKeyBase64: keypair.publicKeyBase64))
    }

    func testManifestRejectsExecutableHashesAlias() throws {
        let hash = String(repeating: "a", count: 64)
        let json = """
        {
          "schemaVersion": 2,
          "toolchainAPI": 2,
          "keyID": "\(hash)",
          "version": "2.0.0",
          "publishedAt": "1970-01-01T00:00:00Z",
          "appVersionRange": {"minimum":"0.2.0-beta.1","maximumExclusive":"0.3.0"},
          "components": [{
            "name": "macos-arm64-core",
            "capabilities": ["runtime.core"],
            "url": "https://example.com/core.zip",
            "sha256": "\(hash)",
            "sizeBytes": 1,
            "expandedSizeBytes": 2,
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

        XCTAssertThrowsError(
            try decoder.decode(ManifestDocument.self, from: Data(json.utf8))
        )
    }

    func testManifestRejectsMissingExpandedClosureDigest() throws {
        let hash = String(repeating: "a", count: 64)
        let json = """
        {
          "schemaVersion": 2,
          "toolchainAPI": 2,
          "keyID": "\(hash)",
          "version": "2.0.0",
          "publishedAt": "1970-01-01T00:00:00Z",
          "appVersionRange": {"minimum":"0.2.0-beta.1","maximumExclusive":"0.3.0"},
          "components": [{
            "name": "macos-arm64-core",
            "capabilities": ["runtime.core"],
            "url": "https://example.com/core.zip",
            "sha256": "\(hash)",
            "sizeBytes": 1,
            "expandedSizeBytes": 1,
            "contents": ["bin/colmap"],
            "criticalFileHashes": {"bin/colmap":"\(hash)"},
            "dependencies": [],
            "requirement": "required"
          }],
          "signatureEd25519": ""
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertThrowsError(
            try decoder.decode(ManifestDocument.self, from: Data(json.utf8))
        )
    }

    func testManifestRejectsSchema1Artifacts() throws {
        let json = """
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertThrowsError(
            try decoder.decode(ManifestDocument.self, from: Data(json.utf8))
        )
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

    func testBuildRejectsInvalidPrivateKey() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let zip = tempDir.appendingPathComponent("toolchain.zip")
        try Data("toolchain".utf8).write(to: zip)

        XCTAssertThrowsError(
            try ManifestBuilder.build(
                version: "0.1.0",
                publishedAt: Date(),
                appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
                components: [
                    ManifestArtifactInput(
                        name: "macos-arm64-core",
                        artifactURL: "https://example.com/toolchain.zip",
                        zipURL: zip,
                        capabilities: ManifestToolDefaults.coreCapabilities,
                        dependencies: [],
                        requirement: .required,
                        contents: ["bin/colmap"],
                        criticalFilePaths: ["bin/colmap"],
                        deriveExactContents: false
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

    private func runZip(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw NSError(domain: "ManifestToolCoreTests", code: 2)
        }
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
