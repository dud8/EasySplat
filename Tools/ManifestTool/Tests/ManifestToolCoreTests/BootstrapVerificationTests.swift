import CryptoKit
import Foundation
import XCTest
@testable import ManifestToolCore

final class BootstrapVerificationTests: XCTestCase {
    func testBootstrapVerifierAcceptsSignedReleaseManifestWithOnlyCoreArchivePresent() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        XCTAssertNoThrow(try ManifestBuilder.verifyBootstrap(
            manifest: fixture.manifest,
            publicKeyBase64: fixture.keypair.publicKeyBase64,
            expectedAppVersion: "0.2.1",
            coreArchive: fixture.coreArchive
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("base.zip").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("small.zip").path))
    }

    func testBootstrapCommandArgumentsRejectUnknownDuplicateAndMissingOptions() throws {
        let allowed: Set<String> = ["--manifest", "--public-key-file", "--app-version", "--core-zip"]
        let unknown = ArgParser(["--manifest", "manifest.json", "--unknown", "value"])
        XCTAssertThrowsError(try unknown.requireOnly(allowed))

        let duplicate = ArgParser(["--manifest", "first.json", "--manifest", "second.json"])
        XCTAssertThrowsError(try duplicate.requireOnly(allowed))

        var missing = ArgParser(["--manifest", "manifest.json"])
        try missing.requireOnly(allowed)
        XCTAssertThrowsError(try missing.require("--core-zip"))

        let inlineKey = ArgParser([
            "--manifest", "manifest.json",
            "--public-key-base64", "key",
            "--app-version", "1.0.0",
            "--core-zip", "core.zip",
        ])
        XCTAssertThrowsError(try inlineKey.requireOnly(allowed))
    }

    func testBootstrapVerifierRejectsWrongKeySignatureAndAppRange() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        XCTAssertThrowsError(try verify(fixture, publicKeyBase64: ManifestBuilder.generateKeypair().publicKeyBase64))

        var badSignature = fixture.manifest
        badSignature.signatureEd25519 = Data(repeating: 0, count: 64).base64EncodedString()
        XCTAssertThrowsError(try verify(fixture, manifest: badSignature))

        let badKeyID = try fixture.resigned {
            $0.keyID = String(repeating: "0", count: 64)
        }
        XCTAssertThrowsError(try verify(fixture, manifest: badKeyID))

        XCTAssertThrowsError(try verify(fixture, expectedAppVersion: "0.3.0"))
    }

    func testBootstrapVerifierRejectsProductionClosurePolicyAndURLDrift() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let mutations: [(inout ManifestDocument) -> Void] = [
            { $0.components.removeLast() },
            { $0.components[0].name = "renamed-core" },
            { $0.components[0].capabilities = ["runtime.core"] },
            { $0.components[1].dependencies = [] },
            { $0.components[2].requirement = .required },
            { $0.components[1].url = $0.components[1].url.replacingOccurrences(of: "https://", with: "http://") },
            { $0.components[1].url = "https://attacker.example/base.zip" },
            { $0.components[1].contents[0] = $0.components[0].contents[0] },
        ]

        for mutation in mutations {
            let manifest = try fixture.resigned(mutation)
            XCTAssertThrowsError(try verify(fixture, manifest: manifest))
        }
    }

    func testBootstrapVerifierBindsEveryCoreArchiveProperty() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let mutations: [(inout ManifestDocument) -> Void] = [
            { $0.components[0].sizeBytes += 1 },
            { $0.components[0].expandedSizeBytes += 1 },
            { $0.components[0].sha256 = String(repeating: "0", count: 64) },
            {
                $0.components[0].contents.append("licenses/additional.txt")
                $0.components[0].contents.sort()
            },
            {
                let path = $0.components[0].criticalFileHashes.keys.sorted()[0]
                $0.components[0].criticalFileHashes[path] = String(repeating: "0", count: 64)
            },
        ]

        for mutation in mutations {
            let manifest = try fixture.resigned(mutation)
            XCTAssertThrowsError(try verify(fixture, manifest: manifest))
        }
    }

    func testBootstrapArchiveInspectionRejectsLinksAndSpecialFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let keypair = ManifestBuilder.generateKeypair()

        let symlinkSource = root.appendingPathComponent("symlink-source", isDirectory: true)
        let symlinkPath = symlinkSource.appendingPathComponent("bin/colmap")
        try FileManager.default.createDirectory(at: symlinkPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: symlinkPath.path, withDestinationPath: "target")
        let symlinkArchive = root.appendingPathComponent("symlink.zip")
        try runZip(arguments: ["-q", "-y", symlinkArchive.path, "bin/colmap"], in: symlinkSource)
        XCTAssertThrowsError(try buildSingleCoreManifest(archive: symlinkArchive, keypair: keypair)) { error in
            XCTAssertTrue(error.localizedDescription.contains("symbolic link"))
        }

        let specialArchive = try makeZip(
            named: "special",
            files: ["bin/colmap": Data("payload".utf8)],
            in: root
        )
        try markFirstCentralDirectoryEntryAsFIFO(in: specialArchive)
        XCTAssertThrowsError(try buildSingleCoreManifest(archive: specialArchive, keypair: keypair)) { error in
            XCTAssertTrue(error.localizedDescription.contains("special file"))
        }
    }

    private func verify(
        _ fixture: BootstrapFixture,
        manifest: ManifestDocument? = nil,
        publicKeyBase64: String? = nil,
        expectedAppVersion: String = "0.2.1"
    ) throws {
        try ManifestBuilder.verifyBootstrap(
            manifest: manifest ?? fixture.manifest,
            publicKeyBase64: publicKeyBase64 ?? fixture.keypair.publicKeyBase64,
            expectedAppVersion: expectedAppVersion,
            coreArchive: fixture.coreArchive
        )
    }

    private func makeFixture() throws -> BootstrapFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let coreArchive = try makeZip(
            named: "bootstrap-core",
            files: Dictionary(uniqueKeysWithValues: ManifestToolDefaults.criticalCoreFiles.map {
                ($0, Data($0.utf8))
            }),
            in: root
        )
        let baseArchive = try makeZip(
            named: "build-base",
            files: Dictionary(uniqueKeysWithValues: ManifestToolDefaults.da3BaseContents.map {
                ($0, Data($0.utf8))
            }),
            in: root
        )
        let smallArchive = try makeZip(
            named: "build-small",
            files: Dictionary(uniqueKeysWithValues: ManifestToolDefaults.da3SmallContents.map {
                ($0, Data($0.utf8))
            }),
            in: root
        )
        let keypair = ManifestBuilder.generateKeypair()
        let urls = ManifestBuilder.releaseComponentURLs(repository: "owner/repository", version: "2.0.0")
        let manifest = try ManifestBuilder.build(
            version: "2.0.0",
            publishedAt: Date(timeIntervalSince1970: 0),
            appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
            components: [
                .init(name: "macos-arm64-core", artifactURL: urls["macos-arm64-core"]!, zipURL: coreArchive, capabilities: ManifestToolDefaults.coreCapabilities, dependencies: [], requirement: .required, criticalFilePaths: ManifestToolDefaults.criticalCoreFiles),
                .init(name: "geometry-da3-base", artifactURL: urls["geometry-da3-base"]!, zipURL: baseArchive, capabilities: ["geometry.da3.runtime", "geometry.da3.base"], dependencies: ["macos-arm64-core"], requirement: .optional, criticalFilePaths: ManifestToolDefaults.da3BaseContents),
                .init(name: "geometry-da3-small", artifactURL: urls["geometry-da3-small"]!, zipURL: smallArchive, capabilities: ["geometry.da3.small"], dependencies: ["geometry-da3-base"], requirement: .optional, criticalFilePaths: ManifestToolDefaults.da3SmallContents),
            ],
            privateKeyBase64: keypair.privateKeyBase64
        )
        try FileManager.default.removeItem(at: baseArchive)
        try FileManager.default.removeItem(at: smallArchive)
        return BootstrapFixture(root: root, coreArchive: coreArchive, keypair: keypair, manifest: manifest)
    }

    private func makeZip(named name: String, files: [String: Data], in root: URL) throws -> URL {
        let source = root.appendingPathComponent("\(name)-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (path, data) in files {
            let destination = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination)
        }
        let archive = root.appendingPathComponent("\(name).zip")
        try runZip(arguments: ["-q", archive.path] + files.keys.sorted(), in: source)
        return archive
    }

    private func runZip(arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw NSError(domain: "BootstrapVerificationTests", code: 1)
        }
    }

    private func buildSingleCoreManifest(
        archive: URL,
        keypair: (publicKeyBase64: String, privateKeyBase64: String)
    ) throws -> ManifestDocument {
        try ManifestBuilder.build(
            version: "2.0.0",
            publishedAt: Date(timeIntervalSince1970: 0),
            appVersionRange: .init(minimum: "0.2.0", maximumExclusive: "0.3.0"),
            components: [
                .init(
                    name: "macos-arm64-core",
                    artifactURL: "https://example.com/core.zip",
                    zipURL: archive,
                    capabilities: ManifestToolDefaults.coreCapabilities,
                    dependencies: [],
                    requirement: .required,
                    criticalFilePaths: ["bin/colmap"]
                ),
            ],
            privateKeyBase64: keypair.privateKeyBase64
        )
    }

    private func markFirstCentralDirectoryEntryAsFIFO(in archive: URL) throws {
        var data = try Data(contentsOf: archive)
        let signature = Data([0x50, 0x4b, 0x01, 0x02])
        guard let range = data.range(of: signature) else {
            throw NSError(domain: "BootstrapVerificationTests", code: 2)
        }
        let externalAttributesOffset = range.lowerBound + 38
        let attributes = UInt32(0o010644) << 16
        for byte in 0..<4 {
            data[externalAttributesOffset + byte] = UInt8((attributes >> UInt32(byte * 8)) & 0xff)
        }
        try data.write(to: archive)
    }
}

private struct BootstrapFixture {
    let root: URL
    let coreArchive: URL
    let keypair: (publicKeyBase64: String, privateKeyBase64: String)
    let manifest: ManifestDocument

    func resigned(_ mutation: (inout ManifestDocument) -> Void) throws -> ManifestDocument {
        var result = manifest
        mutation(&result)
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: XCTUnwrap(Data(base64Encoded: keypair.privateKeyBase64))
        )
        result.signatureEd25519 = try privateKey.signature(
            for: ManifestBuilder.canonicalData(for: result)
        ).base64EncodedString()
        return result
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
