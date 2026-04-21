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

    private func makeTempDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
