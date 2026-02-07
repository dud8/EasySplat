import CryptoKit
import Foundation
import XCTest
@testable import EasySplatCore

@MainActor
final class ToolchainManagerDownloadTests: XCTestCase {
    private final class LockedMessages: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ message: String) {
            lock.lock()
            storage.append(message)
            lock.unlock()
        }

        func all() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    func testDownloadManifestRejectsNon200() async {
        await withEnvironmentAsync(["EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": nil]) {
            let token = UUID().uuidString
            let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
            MockURLProtocol.register(token: token) { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            defer { MockURLProtocol.unregister(token: token) }

            let manager = ToolchainManager(
                runner: MockSubprocessRunner(scripts: []),
                urlSession: makeSession()
            )
            await XCTAssertThrowsErrorAsync({
                _ = try await manager.ensureToolchain(
                    manifestURL: manifestURL,
                    publicKeyBase64: "ignored",
                    targetName: "macos-arm64",
                    onProgress: { _, _ in }
                )
            }, errorHandler: { error in
                guard case ToolchainManager.ToolchainError.downloadFailed = error else {
                    return XCTFail("Expected downloadFailed error, got \(error)")
                }
            })
        }
    }

    func testDownloadManifestInvalidJSON() async {
        await withEnvironmentAsync(["EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": nil]) {
            let token = UUID().uuidString
            let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
            MockURLProtocol.register(token: token) { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, Data("not json".utf8))
            }
            defer { MockURLProtocol.unregister(token: token) }

            let manager = ToolchainManager(
                runner: MockSubprocessRunner(scripts: []),
                urlSession: makeSession()
            )
            await XCTAssertThrowsErrorAsync({
                _ = try await manager.ensureToolchain(
                    manifestURL: manifestURL,
                    publicKeyBase64: "ignored",
                    targetName: "macos-arm64",
                    onProgress: { _, _ in }
                )
            }, errorHandler: { error in
                guard case ToolchainManager.ToolchainError.invalidManifest = error else {
                    return XCTFail("Expected invalidManifest error, got \(error)")
                }
            })
        }
    }

    func testEnsureToolchainHashMismatch() async throws {
        try await withEnvironmentAsync(["EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": nil]) {
            let token = UUID().uuidString
            let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
            let artifactURL = tokenizedURL("https://example.com/toolchain.zip", token: token)

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

            MockURLProtocol.register(token: token) { request in
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
            defer { MockURLProtocol.unregister(token: token) }

            let manager = ToolchainManager(
                runner: MockSubprocessRunner(scripts: []),
                urlSession: makeSession()
            )
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
    }

    func testEnsureToolchainInvalidArtifactURL() async throws {
        try await withEnvironmentAsync(["EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": nil]) {
            let token = UUID().uuidString
            let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
            let artifact = ToolchainManifest.Artifact(
                name: "macos-arm64",
                url: "not a url",
                sha256: "abc",
                sizeBytes: 1,
                contents: ["bin/colmap"]
            )
            let signed = try signedManifest(version: "test-\(UUID().uuidString)", artifacts: [artifact])

            MockURLProtocol.register(token: token) { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, signed.data)
            }
            defer { MockURLProtocol.unregister(token: token) }

            let manager = ToolchainManager(
                runner: MockSubprocessRunner(scripts: []),
                urlSession: makeSession()
            )
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
    }

    func testEnsureToolchainSignatureFailsWithWrongPublicKey() async throws {
        try await withEnvironmentAsync(["EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": nil]) {
            let token = UUID().uuidString
            let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
            let artifactURL = tokenizedURL("https://example.com/toolchain.zip", token: token)
            let artifact = ToolchainManifest.Artifact(
                name: "macos-arm64",
                url: artifactURL.absoluteString,
                sha256: "abc",
                sizeBytes: 1,
                contents: ["bin/colmap"]
            )
            let signed = try signedManifest(version: "test-\(UUID().uuidString)", artifacts: [artifact])

            MockURLProtocol.register(token: token) { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, signed.data)
            }
            defer { MockURLProtocol.unregister(token: token) }

            let manager = ToolchainManager(
                runner: MockSubprocessRunner(scripts: []),
                urlSession: makeSession()
            )
            await XCTAssertThrowsErrorAsync({
                _ = try await manager.ensureToolchain(
                    manifestURL: manifestURL,
                    publicKeyBase64: "wrong-public-key",
                    targetName: "macos-arm64",
                    onProgress: { _, _ in }
                )
            }, errorHandler: { error in
                guard case ToolchainManager.ToolchainError.signatureFailed = error else {
                    return XCTFail("Expected signatureFailed error, got \(error)")
                }
            })
        }
    }

    func testEnsureToolchainThrowsArtifactNotFoundWhenSplitArtifactsMissing() async throws {
        try await withEnvironmentAsync(["EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": nil]) {
            let token = UUID().uuidString
            let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
            let artifactURL = tokenizedURL("https://example.com/core.zip", token: token)
            let artifact = ToolchainManifest.Artifact(
                name: "macos-arm64-core",
                url: artifactURL.absoluteString,
                sha256: "abc",
                sizeBytes: 1,
                contents: ["bin/colmap"]
            )
            let signed = try signedManifest(version: "test-\(UUID().uuidString)", artifacts: [artifact])

            MockURLProtocol.register(token: token) { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, signed.data)
            }
            defer { MockURLProtocol.unregister(token: token) }

            let manager = ToolchainManager(
                runner: MockSubprocessRunner(scripts: []),
                urlSession: makeSession()
            )
            await XCTAssertThrowsErrorAsync({
                _ = try await manager.ensureToolchain(
                    manifestURL: manifestURL,
                    publicKeyBase64: signed.publicKey,
                    targetName: "macos-arm64",
                    onProgress: { _, _ in }
                )
            }, errorHandler: { error in
                guard case ToolchainManager.ToolchainError.artifactNotFound = error else {
                    return XCTFail("Expected artifactNotFound error, got \(error)")
                }
            })
        }
    }

    func testEnsureArtifactEmitsIntegrityAndExpectedContentsProgress() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let token = UUID().uuidString
        let artifactURL = tokenizedURL("https://example.com/models.zip", token: token)
        let zipData = Data("zip-bytes".utf8)
        let zipHash = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()

        let artifact = ToolchainManifest.Artifact(
            name: "macos-arm64-models",
            url: artifactURL.absoluteString,
            sha256: zipHash,
            sizeBytes: UInt64(zipData.count),
            contents: [
                "vggt_mps/models/vggt_model.pt",
                "fastvggt_mps/models/fastvggt_model.pt"
            ]
        )

        MockURLProtocol.register(token: token) { request in
            if request.url == artifactURL {
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, zipData)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        defer { MockURLProtocol.unregister(token: token) }

        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/usr/bin/unzip",
                argsPrefix: ["-o"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { _ in
                    let existingFile = root.appendingPathComponent("vggt_mps/models/vggt_model.pt")
                    try? FileManager.default.createDirectory(
                        at: existingFile.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    FileManager.default.createFile(atPath: existingFile.path, contents: Data([0x00]))
                }
            )
        ])

        let manager = ToolchainManager(runner: runner, urlSession: makeSession())
        let messages = LockedMessages()
        try await manager.test_ensureArtifact(artifact, root: root) { _, message in
            messages.append(message)
        }
        let allMessages = messages.all()

        XCTAssertTrue(allMessages.contains("Verified download integrity (models)"))
        XCTAssertTrue(allMessages.contains("Unpacking tools (models)"))
        XCTAssertTrue(allMessages.contains("Unpacking tools (models): found 1/2 expected files"))
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

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func tokenizedURL(_ base: String, token: String) -> URL {
        var components = URLComponents(string: base)!
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "easysplat_test_token", value: token))
        components.queryItems = items
        return components.url!
    }
}
