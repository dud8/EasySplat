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

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int = 0

        func increment() -> Int {
            lock.lock()
            value += 1
            let current = value
            lock.unlock()
            return current
        }

        func current() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return value
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

    func testEnsureToolchainFallsBackToCachedWhenManifestUnavailable() async throws {
        try await withEnvironmentAsync(["EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": nil]) {
            let token = UUID().uuidString
            let version = "9.9.9-\(UUID().uuidString)"

            let manager = ToolchainManager(
                runner: MockSubprocessRunner(scripts: []),
                urlSession: makeSession()
            )
            let cachedRoot = manager.toolchainRoot().appendingPathComponent(version, isDirectory: true)
            try? FileManager.default.removeItem(at: cachedRoot)
            defer { try? FileManager.default.removeItem(at: cachedRoot) }
            let fixture = try ToolchainFixtureBuilder.createToolchain(at: cachedRoot)

            let runner = MockSubprocessRunner(scripts: validationScripts(for: fixture))
            let validatingManager = ToolchainManager(runner: runner, urlSession: makeSession())
            let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
            MockURLProtocol.register(token: token) { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            defer { MockURLProtocol.unregister(token: token) }

            let messages = LockedMessages()
            let toolchain = try await validatingManager.ensureToolchain(
                manifestURL: manifestURL,
                publicKeyBase64: "ignored",
                targetName: "macos-arm64",
                onProgress: { _, message in
                    messages.append(message)
                }
            )

            XCTAssertEqual(toolchain.root.path, cachedRoot.path)
            let allMessages = messages.all()
            XCTAssertTrue(allMessages.contains("Trying cached tools"))
            XCTAssertTrue(allMessages.contains("Tools ready (offline cached)"))
        }
    }

    func testEnsureToolchainDoesNotFallbackWhenSignatureFailsEvenWithCachedTools() async throws {
        try await withEnvironmentAsync(["EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": nil]) {
            let token = UUID().uuidString
            let version = "7.7.7-\(UUID().uuidString)"
            let manager = ToolchainManager(
                runner: MockSubprocessRunner(scripts: []),
                urlSession: makeSession()
            )
            let cachedRoot = manager.toolchainRoot().appendingPathComponent(version, isDirectory: true)
            try? FileManager.default.removeItem(at: cachedRoot)
            defer { try? FileManager.default.removeItem(at: cachedRoot) }
            _ = try ToolchainFixtureBuilder.createToolchain(at: cachedRoot)

            let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
            let signed = try signedManifest(version: version, artifacts: [])

            MockURLProtocol.register(token: token) { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, signed.data)
            }
            defer { MockURLProtocol.unregister(token: token) }

            await XCTAssertThrowsErrorAsync({
                _ = try await manager.ensureToolchain(
                    manifestURL: manifestURL,
                    publicKeyBase64: "wrong-key",
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

    func testEnsureToolchainInstallFailureKeepsExistingVersionedRoot() async throws {
        try await withEnvironmentAsync(["EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": nil]) {
            let token = UUID().uuidString
            let version = "6.6.6-\(UUID().uuidString)"
            let manager = ToolchainManager(
                runner: MockSubprocessRunner(scripts: []),
                urlSession: makeSession()
            )
            let versionedRoot = manager.toolchainRoot().appendingPathComponent(version, isDirectory: true)
            try? FileManager.default.removeItem(at: versionedRoot)
            defer { try? FileManager.default.removeItem(at: versionedRoot) }
            let fixture = try ToolchainFixtureBuilder.createToolchain(at: versionedRoot)

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
            let signed = try signedManifest(version: version, artifacts: [artifact])

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

            let flakyValidationRunner = MockSubprocessRunner(scripts: [
                .init(
                    path: fixture.colmap.path,
                    argsPrefix: ["-h"],
                    result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "temporary launch failure"),
                    onRun: nil
                )
            ])
            let flakyValidationManager = ToolchainManager(runner: flakyValidationRunner, urlSession: makeSession())

            await XCTAssertThrowsErrorAsync({
                _ = try await flakyValidationManager.ensureToolchain(
                    manifestURL: manifestURL,
                    publicKeyBase64: signed.publicKey,
                    targetName: "macos-arm64",
                    onProgress: { _, _ in }
                )
            }, errorHandler: { error in
                guard case ToolchainManager.ToolchainError.hashMismatch = error else {
                    return XCTFail("Expected hashMismatch error, got \(error)")
                }
            })

            XCTAssertTrue(FileManager.default.fileExists(atPath: versionedRoot.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: versionedRoot.appendingPathComponent("bin/colmap").path))
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

    func testEnsureToolchainRetriesManifestFetchAndSucceeds() async throws {
        try await withEnvironmentAsync(["EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": nil]) {
            let token = UUID().uuidString
            let version = "5.5.5-\(UUID().uuidString)"
            let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
            let requestCounter = LockedCounter()

            let bootstrapManager = ToolchainManager(
                runner: MockSubprocessRunner(scripts: []),
                urlSession: makeSession()
            )
            let cachedRoot = bootstrapManager.toolchainRoot().appendingPathComponent(version, isDirectory: true)
            try? FileManager.default.removeItem(at: cachedRoot)
            defer { try? FileManager.default.removeItem(at: cachedRoot) }
            let fixture = try ToolchainFixtureBuilder.createToolchain(at: cachedRoot)

            let signed = try signedManifest(version: version, artifacts: [])
            MockURLProtocol.register(token: token) { request in
                guard request.url == manifestURL else {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                    return (response, Data())
                }
                if requestCounter.increment() == 1 {
                    throw URLError(.timedOut)
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (response, signed.data)
            }
            defer { MockURLProtocol.unregister(token: token) }

            let validatingRunner = MockSubprocessRunner(scripts: validationScripts(for: fixture))
            let manager = ToolchainManager(runner: validatingRunner, urlSession: makeSession())
            let toolchain = try await manager.ensureToolchain(
                manifestURL: manifestURL,
                publicKeyBase64: signed.publicKey,
                targetName: "macos-arm64",
                onProgress: { _, _ in }
            )

            XCTAssertEqual(toolchain.root.path, cachedRoot.path)
            XCTAssertEqual(requestCounter.current(), 2)
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

    func testEnsureToolchainRedownloadsModelsInsteadOfTrustingInstalledState() async throws {
        try await withEnvironmentAsync(["EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": nil]) {
            let token = UUID().uuidString
            let version = "8.8.8-\(UUID().uuidString)"
            let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
            let coreURL = tokenizedURL("https://example.com/core.zip", token: token)
            let modelsURL = tokenizedURL("https://example.com/models.zip", token: token)
            let coreData = Data("core-zip".utf8)
            let modelsData = Data("models-zip".utf8)
            let coreHash = SHA256.hash(data: coreData).map { String(format: "%02x", $0) }.joined()
            let modelsHash = SHA256.hash(data: modelsData).map { String(format: "%02x", $0) }.joined()
            let coreArtifact = ToolchainManifest.Artifact(
                name: "macos-arm64-core",
                url: coreURL.absoluteString,
                sha256: coreHash,
                sizeBytes: UInt64(coreData.count),
                contents: ["bin/colmap"]
            )
            let modelsArtifact = ToolchainManifest.Artifact(
                name: "macos-arm64-models",
                url: modelsURL.absoluteString,
                sha256: modelsHash,
                sizeBytes: UInt64(modelsData.count),
                contents: [
                    "da3_mps/models/DA3-BASE/model.safetensors",
                    "da3_mps/models/DA3-BASE/config.json",
                    "da3_mps/models/DA3-BASE/easysplat_model_info.json",
                    "da3_mps/models/DA3-SMALL/model.safetensors",
                    "da3_mps/models/DA3-SMALL/config.json",
                    "da3_mps/models/DA3-SMALL/easysplat_model_info.json",
                    "mapanything_mps/models/map-anything-apache/model.safetensors",
                    "mapanything_mps/models/map-anything-apache/config.json",
                    "mapanything_mps/models/dinov2/dinov2_vitg14_pretrain.pth",
                    "vggt_mps/models/vggt_model.pt",
                    "fastvggt_mps/models/fastvggt_model.pt"
                ]
            )
            let signed = try signedManifest(version: version, artifacts: [coreArtifact, modelsArtifact])

            let bootstrapManager = ToolchainManager(runner: MockSubprocessRunner(scripts: []), urlSession: makeSession())
            let versionedRoot = bootstrapManager.toolchainRoot().appendingPathComponent(version, isDirectory: true)
            try? FileManager.default.removeItem(at: versionedRoot)
            defer { try? FileManager.default.removeItem(at: versionedRoot) }
            let fixture = try ToolchainFixtureBuilder.createToolchain(at: versionedRoot)
            let state = ToolchainManager.ToolchainInstallState(installedArtifacts: [modelsArtifact.name: modelsArtifact.sha256])
            let stateData = try JSONEncoder().encode(state)
            try stateData.write(to: versionedRoot.appendingPathComponent(".easysplat_toolchain_state.json"))
            try "tampered".write(to: fixture.da3ModelFile, atomically: true, encoding: .utf8)
            try removeInstalledCore(at: versionedRoot)

            let modelRequestCounter = LockedCounter()
            MockURLProtocol.register(token: token) { request in
                if request.url == manifestURL {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, signed.data)
                }
                if request.url == coreURL {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, coreData)
                }
                if request.url == modelsURL {
                    _ = modelRequestCounter.increment()
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, modelsData)
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            defer { MockURLProtocol.unregister(token: token) }

            let unzipScript = MockSubprocessRunner.Script(
                path: "/usr/bin/unzip",
                argsPrefix: ["-o"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    guard let destinationFlag = args.firstIndex(of: "-d"),
                          args.indices.contains(destinationFlag + 1) else { return }
                    let destination = URL(fileURLWithPath: args[destinationFlag + 1], isDirectory: true)
                    _ = try? ToolchainFixtureBuilder.createToolchain(at: destination)
                }
            )
            let runner = MockSubprocessRunner(scripts: [
                unzipScript,
                unzipScript
            ] + validationScripts(for: fixture))
            let manager = ToolchainManager(runner: runner, urlSession: makeSession())

            let toolchain = try await manager.ensureToolchain(
                manifestURL: manifestURL,
                publicKeyBase64: signed.publicKey,
                targetName: "macos-arm64",
                onProgress: { _, _ in }
            )

            XCTAssertEqual(toolchain.root.path, versionedRoot.path)
            XCTAssertEqual(modelRequestCounter.current(), 1)
        }
    }

    func testEnsureArtifactFailsWhenExpectedContentsMissing() async throws {
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
        await XCTAssertThrowsErrorAsync({
            try await manager.test_ensureArtifact(artifact, root: root) { _, message in
                messages.append(message)
            }
        }, errorHandler: { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain error, got \(error)")
            }
            XCTAssertTrue(message.contains("missing expected files"))
        })
        let allMessages = messages.all()

        XCTAssertTrue(allMessages.contains("Verified download integrity (models)"))
        XCTAssertTrue(allMessages.contains("Unpacking tools (models)"))
        XCTAssertTrue(allMessages.contains("Unpacking tools (models): found 1/2 expected files"))
    }

    func testEnsureArtifactSucceedsWhenExpectedContentsPresent() async throws {
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
            contents: ["vggt_mps/models/vggt_model.pt"]
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
                    let expectedFile = root.appendingPathComponent("vggt_mps/models/vggt_model.pt")
                    try? FileManager.default.createDirectory(
                        at: expectedFile.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    FileManager.default.createFile(atPath: expectedFile.path, contents: Data([0x00]))
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
        XCTAssertTrue(allMessages.contains("Unpacking tools (models): found 1/1 expected files"))
    }

    func testEnsureArtifactRetriesTransientDownloadFailureAndSucceeds() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let token = UUID().uuidString
        let artifactURL = tokenizedURL("https://example.com/models.zip", token: token)
        let zipData = Data("zip-bytes".utf8)
        let zipHash = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        let requestCounter = LockedCounter()

        let artifact = ToolchainManifest.Artifact(
            name: "macos-arm64-models",
            url: artifactURL.absoluteString,
            sha256: zipHash,
            sizeBytes: UInt64(zipData.count),
            contents: ["vggt_mps/models/vggt_model.pt"]
        )

        MockURLProtocol.register(token: token) { request in
            guard request.url == artifactURL else {
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            if requestCounter.increment() == 1 {
                throw URLError(.timedOut)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, zipData)
        }
        defer { MockURLProtocol.unregister(token: token) }

        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/usr/bin/unzip",
                argsPrefix: ["-o"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { _ in
                    let expectedFile = root.appendingPathComponent("vggt_mps/models/vggt_model.pt")
                    try? FileManager.default.createDirectory(
                        at: expectedFile.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    FileManager.default.createFile(atPath: expectedFile.path, contents: Data([0x00]))
                }
            )
        ])

        let manager = ToolchainManager(runner: runner, urlSession: makeSession())
        try await manager.test_ensureArtifact(artifact, root: root) { _, _ in }
        XCTAssertEqual(requestCounter.current(), 2)
    }

    private func validationScripts(for fixture: ToolchainFixture) -> [MockSubprocessRunner.Script] {
        [
            .init(
                path: "/usr/bin/file",
                argsPrefix: ["-b", fixture.colmap.path],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "Mach-O 64-bit executable arm64", stderr: ""),
                onRun: nil
            ),
            .init(
                path: "/usr/bin/file",
                argsPrefix: ["-b", fixture.brush.path],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "Mach-O 64-bit executable arm64", stderr: ""),
                onRun: nil
            ),
            .init(
                path: fixture.colmap.path,
                argsPrefix: ["-h"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: nil
            ),
            .init(
                path: fixture.brush.path,
                argsPrefix: ["--help"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: nil
            ),
            .init(
                path: "/usr/bin/file",
                argsPrefix: ["-b", fixture.da3Python.path],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "Mach-O 64-bit executable arm64", stderr: ""),
                onRun: nil
            ),
            .init(
                path: fixture.da3SfmTool.path,
                argsPrefix: ["--help"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: nil
            ),
            .init(
                path: "/usr/bin/file",
                argsPrefix: ["-b", fixture.mapanythingPython.path],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "Mach-O 64-bit executable arm64", stderr: ""),
                onRun: nil
            ),
            .init(
                path: fixture.mapanythingSfmTool.path,
                argsPrefix: ["--help"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: nil
            ),
            .init(
                path: "/usr/bin/file",
                argsPrefix: ["-b", fixture.vggtPython.path],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "Mach-O 64-bit executable arm64", stderr: ""),
                onRun: nil
            ),
            .init(
                path: fixture.vggtSfmTool.path,
                argsPrefix: ["--help"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: nil
            ),
            .init(
                path: "/usr/bin/file",
                argsPrefix: ["-b", fixture.fastvggtPython.path],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "Mach-O 64-bit executable arm64", stderr: ""),
                onRun: nil
            ),
            .init(
                path: fixture.fastvggtSfmTool.path,
                argsPrefix: ["--help"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: nil
            )
        ]
    }

    private func removeInstalledCore(at root: URL) throws {
        let relativePaths = [
            "bin",
            "lib",
            "da3_mps/bin",
            "da3_mps/python",
            "da3_mps/build_info.json",
            "da3_mps/vendor",
            "da3_mps/app",
            "mapanything_mps/bin",
            "mapanything_mps/python",
            "mapanything_mps/build_info.json",
            "mapanything_mps/vendor",
            "mapanything_mps/app",
            "vggt_mps/bin",
            "vggt_mps/python",
            "vggt_mps/build_info.json",
            "vggt_mps/vendor",
            "vggt_mps/app",
            "fastvggt_mps/bin",
            "fastvggt_mps/python",
            "fastvggt_mps/build_info.json",
            "fastvggt_mps/vendor",
            "fastvggt_mps/app"
        ]
        for path in relativePaths {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(path))
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
