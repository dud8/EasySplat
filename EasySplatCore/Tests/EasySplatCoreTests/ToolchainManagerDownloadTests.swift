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

    func testRemoteURLsRequireHTTPSExceptLoopbackDevelopment() throws {
        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []), urlSession: makeSession())

        XCTAssertEqual(
            try manager.test_validatedRemoteURL("https://downloads.example.com/component.zip").scheme,
            "https"
        )
        XCTAssertEqual(
            try manager.test_validatedRemoteURL("http://localhost:8000/component.zip").host,
            "localhost"
        )
        XCTAssertEqual(
            try manager.test_validatedRemoteURL("http://127.0.0.1:8000/component.zip").host,
            "127.0.0.1"
        )
        XCTAssertThrowsError(try manager.test_validatedRemoteURL("http://example.com/component.zip"))
        XCTAssertThrowsError(try manager.test_validatedRemoteURL("file:///tmp/component.zip"))
    }

    func testRedirectTargetsUseTheSameHTTPSAndLoopbackPolicy() throws {
        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []), urlSession: makeSession())

        XCTAssertNoThrow(
            try manager.test_validateRedirectTarget(URL(string: "https://cdn.example.com/component.zip")!)
        )
        XCTAssertNoThrow(
            try manager.test_validateRedirectTarget(URL(string: "http://127.0.0.1:8000/component.zip")!)
        )
        XCTAssertThrowsError(
            try manager.test_validateRedirectTarget(URL(string: "http://cdn.example.com/component.zip")!)
        )
        XCTAssertThrowsError(
            try manager.test_validateRedirectTarget(URL(fileURLWithPath: "/tmp/component.zip"))
        )

        let response = HTTPURLResponse(
            url: URL(string: "https://downloads.example.com/component.zip")!,
            statusCode: 302,
            httpVersion: nil,
            headerFields: nil
        )!
        let rejectedRequest = URLRequest(url: URL(string: "http://cdn.example.com/component.zip")!)
        let session = makeSession()
        let task = session.dataTask(with: response.url!)
        let dataDelegate = ToolchainManager.RedirectValidationDelegate { url in
            try manager.test_validateRedirectTarget(url)
        }
        var acceptedDataRedirect: URLRequest?
        dataDelegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: rejectedRequest
        ) { acceptedDataRedirect = $0 }
        XCTAssertNil(acceptedDataRedirect)

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloadDelegate = ToolchainManager.DownloadDelegate(
            destination: destination,
            label: "Downloading tools",
            onProgress: { _, _ in },
            fileManager: .default,
            validateRedirect: { url in try manager.test_validateRedirectTarget(url) }
        )
        var acceptedDownloadRedirect: URLRequest?
        downloadDelegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: rejectedRequest
        ) { acceptedDownloadRedirect = $0 }
        XCTAssertNil(acceptedDownloadRedirect)
        session.invalidateAndCancel()
    }

    func testArchiveEntryValidationRejectsTraversalAndAbsolutePaths() throws {
        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []), urlSession: makeSession())

        XCTAssertNoThrow(try manager.test_validateArchiveEntries([
            "bin/colmap",
            "da3_mps/models/DA3-BASE/model.safetensors",
        ]))
        XCTAssertThrowsError(try manager.test_validateArchiveEntries(["../escape"]))
        XCTAssertThrowsError(try manager.test_validateArchiveEntries(["bin/../../escape"]))
        XCTAssertThrowsError(try manager.test_validateArchiveEntries(["/tmp/escape"]))
        XCTAssertThrowsError(try manager.test_validateArchiveEntries(["bin\\escape"]))
    }

    func testCriticalExecutableHashesAreEnforced() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("bin/colmap")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("colmap".utf8).write(to: executable)

        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []), urlSession: makeSession())
        let expected = try manager.test_sha256Hex(url: executable)
        XCTAssertNoThrow(try manager.test_validateExecutableHashes(["bin/colmap": expected], root: root))
        XCTAssertThrowsError(
            try manager.test_validateExecutableHashes(
                ["bin/colmap": String(repeating: "0", count: 64)],
                root: root
            )
        )
    }

    func testSignedReceiptRejectsMutatedCachedModelFiles() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1"
        )

        let corePaths = Array(ToolchainManager.criticalCoreExecutables).sorted()
        let basePaths = [
            "da3_mps/models/DA3-BASE/config.json",
            "da3_mps/models/DA3-BASE/easysplat_model_info.json",
            "da3_mps/models/DA3-BASE/model.safetensors",
        ]
        let smallPaths = [
            "da3_mps/models/DA3-SMALL/config.json",
            "da3_mps/models/DA3-SMALL/easysplat_model_info.json",
            "da3_mps/models/DA3-SMALL/model.safetensors",
        ]
        func hashes(for paths: [String]) throws -> [String: String] {
            try Dictionary(uniqueKeysWithValues: paths.map { path in
                (path, try manager.test_sha256Hex(url: root.appendingPathComponent(path)))
            })
        }

        let unsigned = ToolchainManifest(
            schemaVersion: 2,
            toolchainAPI: 2,
            keyID: "",
            version: "2.0.0",
            publishedAt: Date(),
            appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
            components: [
                .init(name: "macos-arm64-core", capabilities: Array(ToolchainManager.coreCapabilities), url: "https://example.com/core.zip", sha256: String(repeating: "a", count: 64), sizeBytes: 1, contents: corePaths, criticalFileHashes: try hashes(for: corePaths), dependencies: [], requirement: .required),
                .init(name: "geometry-da3-base", capabilities: [ToolchainCapability.da3Base.rawValue], url: "https://example.com/base.zip", sha256: String(repeating: "b", count: 64), sizeBytes: 1, contents: basePaths, criticalFileHashes: try hashes(for: basePaths), dependencies: ["macos-arm64-core"], requirement: .required),
                .init(name: "geometry-da3-small", capabilities: [ToolchainCapability.da3Small.rawValue], url: "https://example.com/small.zip", sha256: String(repeating: "c", count: 64), sizeBytes: 1, contents: smallPaths, criticalFileHashes: try hashes(for: smallPaths), dependencies: ["macos-arm64-core"], requirement: .optional),
            ],
            signatureEd25519: ""
        )
        let signed = try signedV2Manifest(unsigned)
        try manager.saveInstallState(
            .init(
                schemaVersion: 2,
                installedArtifacts: [
                    "macos-arm64-core": String(repeating: "a", count: 64),
                    "geometry-da3-base": String(repeating: "b", count: 64),
                ],
                installedCapabilities: Array(ToolchainManager.coreCapabilities).sorted() + [ToolchainCapability.da3Base.rawValue],
                signedManifest: signed.manifest
            ),
            root: root
        )

        XCTAssertNoThrow(
            try manager.test_validateSignedReceipt(
                root: root,
                publicKeyBase64: signed.publicKey,
                request: .init(capabilities: [.da3Base])
            )
        )
        try Data("corrupt".utf8).write(to: root.appendingPathComponent(basePaths[2]), options: .atomic)
        XCTAssertThrowsError(
            try manager.test_validateSignedReceipt(
                root: root,
                publicKeyBase64: signed.publicKey,
                request: .init(capabilities: [.da3Base])
            )
        )
    }

    func testInterruptedStagingAndBackupRecoverMostCompleteValidInstall() throws {
        let toolchainsRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: toolchainsRoot) }
        let version = "2.7.0-beta.1"
        let backupRoot = toolchainsRoot.appendingPathComponent("\(version).backup-test", isDirectory: true)
        _ = try ToolchainFixtureBuilder.createToolchain(at: backupRoot)
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1"
        )

        let corePaths = Array(ToolchainManager.criticalCoreExecutables).sorted()
        let basePaths = [
            "da3_mps/models/DA3-BASE/config.json",
            "da3_mps/models/DA3-BASE/easysplat_model_info.json",
            "da3_mps/models/DA3-BASE/model.safetensors",
        ]
        let smallPaths = [
            "da3_mps/models/DA3-SMALL/config.json",
            "da3_mps/models/DA3-SMALL/easysplat_model_info.json",
            "da3_mps/models/DA3-SMALL/model.safetensors",
        ]
        func hashes(for paths: [String]) throws -> [String: String] {
            try Dictionary(uniqueKeysWithValues: paths.map { path in
                (path, try manager.test_sha256Hex(url: backupRoot.appendingPathComponent(path)))
            })
        }
        let unsigned = ToolchainManifest(
            schemaVersion: 2,
            toolchainAPI: 2,
            keyID: "",
            version: version,
            publishedAt: Date(),
            appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
            components: [
                .init(name: "macos-arm64-core", capabilities: Array(ToolchainManager.coreCapabilities), url: "https://example.com/core.zip", sha256: String(repeating: "a", count: 64), sizeBytes: 1, contents: corePaths, criticalFileHashes: try hashes(for: corePaths), dependencies: [], requirement: .required),
                .init(name: "geometry-da3-base", capabilities: [ToolchainCapability.da3Base.rawValue], url: "https://example.com/base.zip", sha256: String(repeating: "b", count: 64), sizeBytes: 1, contents: basePaths, criticalFileHashes: try hashes(for: basePaths), dependencies: ["macos-arm64-core"], requirement: .required),
                .init(name: "geometry-da3-small", capabilities: [ToolchainCapability.da3Small.rawValue], url: "https://example.com/small.zip", sha256: String(repeating: "c", count: 64), sizeBytes: 1, contents: smallPaths, criticalFileHashes: try hashes(for: smallPaths), dependencies: ["macos-arm64-core"], requirement: .optional),
            ],
            signatureEd25519: ""
        )
        let signed = try signedV2Manifest(unsigned)
        try manager.saveInstallState(
            .init(
                schemaVersion: 2,
                installedArtifacts: Dictionary(uniqueKeysWithValues: signed.manifest.components.prefix(2).map { ($0.name, $0.sha256) }),
                installedCapabilities: signed.manifest.components.prefix(2).flatMap(\.capabilities),
                signedManifest: signed.manifest
            ),
            root: backupRoot
        )
        let canonical = toolchainsRoot.appendingPathComponent(version, isDirectory: true)
        try FileManager.default.copyItem(at: backupRoot, to: canonical)
        let stagingRoot = toolchainsRoot.appendingPathComponent("\(version).staging-test", isDirectory: true)
        try FileManager.default.copyItem(at: backupRoot, to: stagingRoot)
        try manager.saveInstallState(
            .init(
                schemaVersion: 2,
                installedArtifacts: Dictionary(uniqueKeysWithValues: signed.manifest.components.map { ($0.name, $0.sha256) }),
                installedCapabilities: signed.manifest.components.flatMap(\.capabilities),
                signedManifest: signed.manifest
            ),
            root: stagingRoot
        )

        try manager.test_recoverInterruptedInstalls(
            at: toolchainsRoot,
            publicKeyBase64: signed.publicKey
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: canonical.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.path))
        XCTAssertEqual(manager.loadInstallState(root: canonical).installedArtifacts.count, 3)
    }

    func testAtomicReplacementRestoresPriorInstallWhenPromotedTreeFailsValidation() async throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let versionedRoot = parent.appendingPathComponent("2.0.0", isDirectory: true)
        _ = try ToolchainFixtureBuilder.createToolchain(at: versionedRoot)
        let marker = versionedRoot.appendingPathComponent("existing-install.marker")
        try Data("keep".utf8).write(to: marker)
        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []), urlSession: makeSession())

        let replacement = Task.detached {
            try await manager.installToolchainAtomically(
                versionedRoot: versionedRoot,
                onProgress: { _, _ in }
            ) { stagingRoot in
                try Data("invalid".utf8).write(to: stagingRoot.appendingPathComponent("incomplete.marker"))
            }
        }
        do {
            _ = try await replacement.value
            XCTFail("Expected the incomplete replacement to fail validation")
        } catch {
            // Expected: the replacement lacks the required toolchain closure.
        }

        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            .filter { $0.contains(".backup-") || $0.contains(".staging-") }
        XCTAssertTrue(leftovers.isEmpty)
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

    func testEnsureToolchainRedownloadsSplitArtifactsWhenCoreInstallIsMissing() async throws {
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
                    "da3_mps/models/DA3-SMALL/easysplat_model_info.json"
                ]
            )
            let signed = try signedManifest(version: version, artifacts: [coreArtifact, modelsArtifact])

            let bootstrapManager = ToolchainManager(runner: MockSubprocessRunner(scripts: []), urlSession: makeSession())
            let versionedRoot = bootstrapManager.toolchainRoot().appendingPathComponent(version, isDirectory: true)
            try? FileManager.default.removeItem(at: versionedRoot)
            defer { try? FileManager.default.removeItem(at: versionedRoot) }
            let fixture = try ToolchainFixtureBuilder.createToolchain(at: versionedRoot)
            let state = ToolchainManager.ToolchainInstallState(installedArtifacts: [
                coreArtifact.name: coreArtifact.sha256,
                modelsArtifact.name: modelsArtifact.sha256
            ])
            let stateData = try JSONEncoder().encode(state)
            try stateData.write(to: versionedRoot.appendingPathComponent(".easysplat_toolchain_state.json"))
            try removeInstalledCore(at: versionedRoot)

            let coreRequestCounter = LockedCounter()
            let modelRequestCounter = LockedCounter()
            MockURLProtocol.register(token: token) { request in
                if request.url == manifestURL {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, signed.data)
                }
                if request.url == coreURL {
                    _ = coreRequestCounter.increment()
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
                onRun: { @Sendable args in
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
            XCTAssertEqual(coreRequestCounter.current(), 1)
            XCTAssertEqual(modelRequestCounter.current(), 1)
        }
    }

    func testSchema2IncrementalCapabilityInstallPreservesExistingModelAndDownloadsOnlyDelta() async throws {
        try await withEnvironmentAsync(["EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": nil]) {
            for firstCapability in [ToolchainCapability.da3Base, .da3Small] {
            let secondCapability: ToolchainCapability = firstCapability == .da3Base ? .da3Small : .da3Base
            let token = UUID().uuidString
            let version = "2.4.\(Int.random(in: 1000...9999))"
            let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
            let coreURL = tokenizedURL("https://example.com/core.zip", token: token)
            let baseURL = tokenizedURL("https://example.com/base.zip", token: token)
            let smallURL = tokenizedURL("https://example.com/small.zip", token: token)
            let coreData = Data("core-component".utf8)
            let baseData = Data("base-component".utf8)
            let smallData = Data("small-component".utf8)

            let bootstrap = ToolchainManager(runner: MockSubprocessRunner(scripts: []), localToolchainRoot: nil)
            let versionedRoot = bootstrap.toolchainRoot().appendingPathComponent(version, isDirectory: true)
            try? FileManager.default.removeItem(at: versionedRoot)
            let seedFixture = try ToolchainFixtureBuilder.createToolchain(at: versionedRoot)
            let executableHashes = try Dictionary(uniqueKeysWithValues: [
                "bin/colmap",
                "bin/easysplat-train",
                "da3_mps/bin/easysplat_da3_sfm",
                "da3_mps/python/bin/python3",
            ].map { path in
                (path, try bootstrap.test_sha256Hex(url: versionedRoot.appendingPathComponent(path)))
            })
            try FileManager.default.removeItem(at: versionedRoot)
            defer { try? FileManager.default.removeItem(at: versionedRoot) }

            func componentHash(_ data: Data) -> String {
                SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            let baseContents = [
                "da3_mps/models/DA3-BASE/model.safetensors",
                "da3_mps/models/DA3-BASE/config.json",
                "da3_mps/models/DA3-BASE/easysplat_model_info.json",
            ]
            let smallContents = [
                "da3_mps/models/DA3-SMALL/model.safetensors",
                "da3_mps/models/DA3-SMALL/config.json",
                "da3_mps/models/DA3-SMALL/easysplat_model_info.json",
            ]
            let baseCriticalHashes = Dictionary(
                uniqueKeysWithValues: baseContents.map { ($0, componentHash(Data([0x01]))) }
            )
            let smallCriticalHashes = Dictionary(
                uniqueKeysWithValues: smallContents.map { ($0, componentHash(Data([0x02]))) }
            )
            let manifest = ToolchainManifest(
                schemaVersion: 2,
                toolchainAPI: 2,
                keyID: "",
                version: version,
                publishedAt: Date(),
                appVersionRange: .init(minimum: "1.0.0", maximumExclusive: "3.0.0"),
                components: [
                    .init(name: "macos-arm64-core", capabilities: ["runtime.core", "geometry.colmap", "geometry.da3.runtime", "training.msplat"], url: coreURL.absoluteString, sha256: componentHash(coreData), sizeBytes: UInt64(coreData.count), contents: Array(executableHashes.keys), criticalFileHashes: executableHashes, dependencies: [], requirement: .required),
                    .init(name: "geometry-da3-base", capabilities: ["geometry.da3.base"], url: baseURL.absoluteString, sha256: componentHash(baseData), sizeBytes: UInt64(baseData.count), contents: baseContents, criticalFileHashes: baseCriticalHashes, dependencies: ["macos-arm64-core"], requirement: .required),
                    .init(name: "geometry-da3-small", capabilities: ["geometry.da3.small"], url: smallURL.absoluteString, sha256: componentHash(smallData), sizeBytes: UInt64(smallData.count), contents: smallContents, criticalFileHashes: smallCriticalHashes, dependencies: ["macos-arm64-core"], requirement: .optional),
                ],
                signatureEd25519: ""
            )
            let signed = try signedV2Manifest(manifest)

            let coreRequests = LockedCounter()
            let baseRequests = LockedCounter()
            let smallRequests = LockedCounter()
            let manifestRequests = LockedCounter()
            MockURLProtocol.register(token: token) { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                switch request.url {
                case manifestURL:
                    if manifestRequests.increment() <= 2 {
                        return (response, signed.data)
                    }
                    return (
                        HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!,
                        Data()
                    )
                case coreURL:
                    _ = coreRequests.increment()
                    return (response, coreData)
                case baseURL:
                    _ = baseRequests.increment()
                    return (response, baseData)
                case smallURL:
                    _ = smallRequests.increment()
                    return (response, smallData)
                default:
                    return (HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
                }
            }
            defer { MockURLProtocol.unregister(token: token) }

            let coreUnzip = MockSubprocessRunner.Script(
                path: "/usr/bin/unzip",
                argsPrefix: ["-o"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { @Sendable args in
                    guard let index = args.firstIndex(of: "-d") else { return }
                    let destination = URL(fileURLWithPath: args[index + 1], isDirectory: true)
                    _ = try? ToolchainFixtureBuilder.createToolchain(at: destination)
                    try? FileManager.default.removeItem(at: destination.appendingPathComponent("da3_mps/models"))
                }
            )
            let baseUnzip = MockSubprocessRunner.Script(
                path: "/usr/bin/unzip",
                argsPrefix: ["-o"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { @Sendable args in
                    guard let index = args.firstIndex(of: "-d") else { return }
                    let destination = URL(fileURLWithPath: args[index + 1], isDirectory: true)
                    for path in baseContents {
                        let file = destination.appendingPathComponent(path)
                        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                        FileManager.default.createFile(atPath: file.path, contents: Data([0x01]))
                    }
                }
            )
            let smallUnzip = MockSubprocessRunner.Script(
                path: "/usr/bin/unzip",
                argsPrefix: ["-o"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { @Sendable args in
                    guard let index = args.firstIndex(of: "-d") else { return }
                    let destination = URL(fileURLWithPath: args[index + 1], isDirectory: true)
                    for path in smallContents {
                        let file = destination.appendingPathComponent(path)
                        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                        FileManager.default.createFile(atPath: file.path, contents: Data([0x02]))
                    }
                }
            )
            let firstModelUnzip = firstCapability == .da3Base ? baseUnzip : smallUnzip
            let secondModelUnzip = firstCapability == .da3Base ? smallUnzip : baseUnzip
            let runner = MockSubprocessRunner(
                scripts: [coreUnzip, firstModelUnzip, secondModelUnzip]
                    + validationScripts(for: seedFixture)
                    + validationScripts(for: seedFixture)
                    + validationScripts(for: seedFixture)
                    + validationScripts(for: seedFixture)
            )
            let manager = ToolchainManager(
                runner: runner,
                urlSession: makeSession(),
                appVersion: "2.0.0",
                localToolchainRoot: nil
            )

            let toolchain = try await manager.ensureToolchain(
                manifestURL: manifestURL,
                publicKeyBase64: signed.publicKey,
                request: .init(capabilities: [firstCapability]),
                onProgress: { _, _ in }
            )

            XCTAssertEqual(toolchain.root, versionedRoot)
            XCTAssertEqual(coreRequests.current(), 1)
            XCTAssertEqual(baseRequests.current(), firstCapability == .da3Base ? 1 : 0)
            XCTAssertEqual(smallRequests.current(), firstCapability == .da3Small ? 1 : 0)
            let missingModelPath = firstCapability == .da3Base
                ? "da3_mps/models/DA3-SMALL"
                : "da3_mps/models/DA3-BASE"
            XCTAssertFalse(FileManager.default.fileExists(atPath: versionedRoot.appendingPathComponent(missingModelPath).path))
            let receipt = manager.loadInstallState(root: versionedRoot)
            let firstComponentName = firstCapability == .da3Base ? "geometry-da3-base" : "geometry-da3-small"
            XCTAssertEqual(Set(receipt.installedArtifacts.keys), ["macos-arm64-core", firstComponentName])
            XCTAssertEqual(
                Set(receipt.installedCapabilities),
                Set(ToolchainManager.coreCapabilities).union([firstCapability.rawValue])
            )

            _ = try await manager.ensureToolchain(
                manifestURL: manifestURL,
                publicKeyBase64: signed.publicKey,
                request: .init(capabilities: [secondCapability]),
                onProgress: { _, _ in }
            )

            XCTAssertEqual(coreRequests.current(), 1, "verified core should be reused")
            XCTAssertEqual(baseRequests.current(), 1)
            XCTAssertEqual(smallRequests.current(), 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: versionedRoot.appendingPathComponent(baseContents[0]).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: versionedRoot.appendingPathComponent(smallContents[0]).path))
            let expandedReceipt = manager.loadInstallState(root: versionedRoot)
            XCTAssertEqual(
                Set(expandedReceipt.installedArtifacts.keys),
                ["macos-arm64-core", "geometry-da3-base", "geometry-da3-small"]
            )
            XCTAssertTrue(ToolchainCapabilityRequest.default.manifestCapabilities.isSubset(of: Set(expandedReceipt.installedCapabilities)))

            for offlineCapability in [ToolchainCapability.da3Base, .da3Small] {
                _ = try await manager.ensureToolchain(
                    manifestURL: manifestURL,
                    publicKeyBase64: signed.publicKey,
                    request: .init(capabilities: [offlineCapability]),
                    onProgress: { _, _ in }
                )
            }
            XCTAssertEqual(coreRequests.current(), 1)
            XCTAssertEqual(baseRequests.current(), 1)
            XCTAssertEqual(smallRequests.current(), 1)
            }
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
                "da3_mps/models/DA3-BASE/model.safetensors",
                "da3_mps/models/DA3-SMALL/model.safetensors"
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
                onRun: { @Sendable _ in
                    let existingFile = root.appendingPathComponent("da3_mps/models/DA3-BASE/model.safetensors")
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
            contents: ["da3_mps/models/DA3-BASE/model.safetensors"]
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
                onRun: { @Sendable _ in
                    let expectedFile = root.appendingPathComponent("da3_mps/models/DA3-BASE/model.safetensors")
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
            contents: ["da3_mps/models/DA3-BASE/model.safetensors"]
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
                onRun: { @Sendable _ in
                    let expectedFile = root.appendingPathComponent("da3_mps/models/DA3-BASE/model.safetensors")
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
        let msplat = fixture.root.appendingPathComponent("bin/easysplat-train")
        return [
            .init(
                path: "/usr/bin/file",
                argsPrefix: ["-b", fixture.colmap.path],
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
                path: fixture.colmap.path,
                argsPrefix: ["global_mapper"],
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
                argsPrefix: ["-b", msplat.path],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "Mach-O 64-bit executable arm64", stderr: ""),
                onRun: nil
            ),
            .init(
                path: msplat.path,
                argsPrefix: ["--self-check", "--events-fd", "1"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "{\"event\":\"self_check\",\"schema_version\":1,\"sequence\":1,\"status\":\"ok\",\"version\":\"1.1.3 (git 106499b)\"}\n",
                    stderr: ""
                ),
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
            "da3_mps/app"
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

    private func signedV2Manifest(_ unsigned: ToolchainManifest) throws -> (manifest: ToolchainManifest, publicKey: String, data: Data) {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        var manifest = unsigned
        manifest.keyID = ToolchainManifest.keyID(publicKeyBase64: publicKey)!
        manifest.signatureEd25519 = try key.signature(for: manifest.canonicalData()).base64EncodedString()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (manifest, publicKey, try encoder.encode(manifest))
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
