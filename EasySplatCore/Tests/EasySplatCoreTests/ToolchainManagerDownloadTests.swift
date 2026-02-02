import CryptoKit
import Foundation
import XCTest
@testable import EasySplatCore

@MainActor
final class ToolchainManagerDownloadTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocol.registerClass(MockURLProtocol.self)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        URLProtocol.unregisterClass(MockURLProtocol.self)
        super.tearDown()
    }

    func testDownloadManifestRejectsNon200() async {
        let manifestURL = URL(string: "https://example.com/manifest.json")!
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []))
        await XCTAssertThrowsErrorAsync {
            _ = try await manager.ensureToolchain(
                manifestURL: manifestURL,
                publicKeyBase64: "ignored",
                targetName: "macos-arm64",
                onProgress: { _, _ in }
            )
        }
    }

    func testDownloadManifestInvalidJSON() async {
        let manifestURL = URL(string: "https://example.com/manifest.json")!
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data("not json".utf8))
        }

        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []))
        await XCTAssertThrowsErrorAsync {
            _ = try await manager.ensureToolchain(
                manifestURL: manifestURL,
                publicKeyBase64: "ignored",
                targetName: "macos-arm64",
                onProgress: { _, _ in }
            )
        }
    }

    func testEnsureToolchainHashMismatch() async throws {
        let previousOverride = getenv("EASYSPLAT_LOCAL_TOOLCHAIN_ROOT").map { String(cString: $0) }
        unsetenv("EASYSPLAT_LOCAL_TOOLCHAIN_ROOT")
        defer {
            if let previousOverride {
                setenv("EASYSPLAT_LOCAL_TOOLCHAIN_ROOT", previousOverride, 1)
            } else {
                unsetenv("EASYSPLAT_LOCAL_TOOLCHAIN_ROOT")
            }
        }
        let manifestURL = URL(string: "https://example.com/manifest.json")!
        let artifactURL = URL(string: "https://example.com/toolchain.zip")!

        let expectedData = Data("expected".utf8)
        let expectedHash = SHA256.hash(data: expectedData).map { String(format: "%02x", $0) }.joined()
        let actualData = Data("actual".utf8)

        let artifact = ToolchainManifest.Artifact(
            name: "macos-arm64",
            url: artifactURL.absoluteString,
            sha256: expectedHash,
            sizeBytes: UInt64(expectedData.count),
            contents: ["bin/colmap"]
        )
        let signed = try signedManifest(version: "test-\(UUID().uuidString)", artifacts: [artifact])

        MockURLProtocol.requestHandler = { request in
            if request.url == manifestURL {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, signed.data)
            }
            if request.url == artifactURL {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, actualData)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []))
        do {
            _ = try await manager.ensureToolchain(
                manifestURL: manifestURL,
                publicKeyBase64: signed.publicKey,
                targetName: "macos-arm64",
                onProgress: { _, _ in }
            )
            XCTFail("Expected hash mismatch")
        } catch {
            guard case ToolchainManager.ToolchainError.hashMismatch = error else {
                return XCTFail("Expected hashMismatch error")
            }
        }
    }

    func testEnsureToolchainInvalidArtifactURL() async throws {
        unsetenv("EASYSPLAT_LOCAL_TOOLCHAIN_ROOT")
        let manifestURL = URL(string: "https://example.com/manifest.json")!
        let artifact = ToolchainManifest.Artifact(
            name: "macos-arm64",
            url: "not a url",
            sha256: "abc",
            sizeBytes: 1,
            contents: ["bin/colmap"]
        )
        let signed = try signedManifest(version: "test-\(UUID().uuidString)", artifacts: [artifact])

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, signed.data)
        }

        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []))
        do {
            _ = try await manager.ensureToolchain(
                manifestURL: manifestURL,
                publicKeyBase64: signed.publicKey,
                targetName: "macos-arm64",
                onProgress: { _, _ in }
            )
            XCTFail("Expected invalid artifact URL error")
        } catch {
            guard case ToolchainManager.ToolchainError.invalidArtifactURL = error else {
                return XCTFail("Expected invalidArtifactURL error, got \(error)")
            }
        }
    }

    private func signedManifest(version: String, artifacts: [ToolchainManifest.Artifact]) throws -> (manifest: ToolchainManifest, publicKey: String, data: Data) {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

        var manifest = ToolchainManifest(version: version, publishedAt: Date(), artifacts: artifacts, signatureEd25519: "")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var signable = manifest
        signable.signatureEd25519 = ""
        let data = try encoder.encode(signable)
        let signature = try key.signature(for: data)
        manifest.signatureEd25519 = Data(signature).base64EncodedString()
        let finalData = try encoder.encode(manifest)
        return (manifest, publicKey, finalData)
    }
}
