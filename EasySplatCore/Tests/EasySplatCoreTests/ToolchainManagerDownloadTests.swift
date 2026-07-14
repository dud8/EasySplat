import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import EasySplatCore

@MainActor
final class ToolchainManagerDownloadTests: XCTestCase {
    private static let coreFixtureContents = [
        "bin/colmap",
        "bin/easysplat-train",
        "bin/default.metallib",
        "da3_mps/bin/easysplat_da3_sfm",
        "da3_mps/python/bin/python3",
        "da3_mps/app/easysplat_da3_sfm/run.py",
        "da3_mps/vendor/depth-anything-3/src/depth_anything_3/api.py",
        "da3_mps/build_info.json",
        "msplat/build_info.json",
        "msplat/LICENSE",
        "provenance/colmap.json",
        "supply-chain/components.json",
    ]

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

    func testLoadInstallStateIgnoresSymlinkedReceipt() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let outsideURL = root.appendingPathComponent("outside-state.json")
        let stateURL = root.appendingPathComponent(".easysplat_toolchain_state.json")
        let state = ToolchainManager.ToolchainInstallState(
            installedArtifacts: ["macos-arm64-core": String(repeating: "a", count: 64)]
        )
        try JSONEncoder().encode(state).write(to: outsideURL)
        try FileManager.default.createSymbolicLink(at: stateURL, withDestinationURL: outsideURL)
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession()
        )

        XCTAssertTrue(manager.loadInstallState(root: root).installedArtifacts.isEmpty)
    }

    func testLoadInstallStateAcceptsReceiptBetweenOneAndSixteenMiB() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent(".easysplat_toolchain_state.json")
        let state = ToolchainManager.ToolchainInstallState(
            installedArtifacts: ["macos-arm64-core": String(repeating: "a", count: 2 * 1_024 * 1_024)]
        )
        let data = try JSONEncoder().encode(state)
        XCTAssertGreaterThan(data.count, 1_024 * 1_024)
        XCTAssertLessThan(data.count, 16 * 1_024 * 1_024)
        try data.write(to: stateURL)
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession()
        )

        XCTAssertFalse(manager.loadInstallState(root: root).installedArtifacts.isEmpty)
    }

    func testLoadInstallStateIgnoresReceiptLargerThanSixteenMiB() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent(".easysplat_toolchain_state.json")
        let state = ToolchainManager.ToolchainInstallState(
            installedArtifacts: ["macos-arm64-core": String(repeating: "a", count: 64)]
        )
        var data = try JSONEncoder().encode(state)
        data.append(Data(repeating: 0x20, count: 16 * 1_024 * 1_024))
        XCTAssertGreaterThan(data.count, 16 * 1_024 * 1_024)
        try data.write(to: stateURL)
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession()
        )

        XCTAssertTrue(manager.loadInstallState(root: root).installedArtifacts.isEmpty)
    }

    func testRemoteURLsRequireHTTPSByDefault() throws {
        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []), urlSession: makeSession())

        XCTAssertEqual(
            try manager.test_validatedRemoteURL("https://downloads.example.com/component.zip").scheme,
            "https"
        )
        XCTAssertThrowsError(try manager.test_validatedRemoteURL("http://localhost:8000/component.zip"))
        XCTAssertThrowsError(try manager.test_validatedRemoteURL("http://127.0.0.1:8000/component.zip"))
        XCTAssertThrowsError(try manager.test_validatedRemoteURL("http://[::1]:8000/component.zip"))
        XCTAssertThrowsError(try manager.test_validatedRemoteURL("http://example.com/component.zip"))
        XCTAssertThrowsError(try manager.test_validatedRemoteURL("file:///tmp/component.zip"))
    }

    func testRemoteURLsAllowLoopbackHTTPOnlyWhenExplicitlyEnabled() throws {
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            allowInsecureLoopbackHTTP: true
        )

        XCTAssertEqual(
            try manager.test_validatedRemoteURL("http://localhost:8000/component.zip").host,
            "localhost"
        )
        XCTAssertEqual(
            try manager.test_validatedRemoteURL("http://127.0.0.1:8000/component.zip").host,
            "127.0.0.1"
        )
        XCTAssertEqual(
            try manager.test_validatedRemoteURL("http://[::1]:8000/component.zip").host,
            "::1"
        )
        XCTAssertThrowsError(try manager.test_validatedRemoteURL("http://example.com/component.zip"))
    }

    func testVersionedToolchainRootMustBeOneStrictSemVerChild() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            installationRoot: root
        )

        let valid = try manager.test_versionedToolchainRoot(for: "2.0.0-beta.1")
        XCTAssertEqual(valid.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
        XCTAssertThrowsError(try manager.test_versionedToolchainRoot(for: "../../Documents"))
        XCTAssertThrowsError(try manager.test_versionedToolchainRoot(for: "/tmp/2.0.0"))
        XCTAssertThrowsError(try manager.test_versionedToolchainRoot(for: "2.0.0/escape"))
    }

    func testRedirectTargetsUseTheSameHTTPSAndLoopbackPolicy() throws {
        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []), urlSession: makeSession())
        let developmentManager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            allowInsecureLoopbackHTTP: true
        )

        XCTAssertNoThrow(
            try manager.test_validateRedirectTarget(URL(string: "https://cdn.example.com/component.zip")!)
        )
        XCTAssertThrowsError(
            try manager.test_validateRedirectTarget(URL(string: "http://127.0.0.1:8000/component.zip")!)
        )
        XCTAssertNoThrow(
            try developmentManager.test_validateRedirectTarget(URL(string: "http://127.0.0.1:8000/component.zip")!)
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
        session.invalidateAndCancel()
    }

    func testStreamingDownloadDelegateAppendsAValidatedRange() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let partialURL = root.appendingPathComponent("component.partial")
        try Data("zip-".utf8).write(to: partialURL)
        let completeData = Data("zip-bytes".utf8)
        let session = makeSession()
        let task = session.dataTask(with: URL(string: "https://example.com/component.zip")!)
        let delegate = ToolchainManager.ResumableDownloadDelegate(
            partialURL: partialURL,
            expectedSize: UInt64(completeData.count),
            initialOffset: 4,
            label: "Downloading tools",
            onProgress: { _, _ in },
            fileManager: .default,
            validateRedirect: { _ in }
        )
        let response = HTTPURLResponse(
            url: task.originalRequest!.url!,
            statusCode: 206,
            httpVersion: nil,
            headerFields: [
                "Content-Length": "5",
                "Content-Range": "bytes 4-8/9",
            ]
        )!
        var disposition: URLSession.ResponseDisposition?

        delegate.urlSession(session, dataTask: task, didReceive: response) {
            disposition = $0
        }
        delegate.urlSession(session, dataTask: task, didReceive: Data("bytes".utf8))
        delegate.urlSession(session, task: task, didCompleteWithError: nil)

        XCTAssertEqual(disposition, .allow)
        XCTAssertEqual(try Data(contentsOf: partialURL), completeData)
        session.invalidateAndCancel()
    }

    func testResumableResponseRejectsEncodedArtifactBytes() {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com/component.zip")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Encoding": "gzip"]
        )!

        XCTAssertNil(
            ToolchainManager.resumableResponseMode(
                for: response,
                requestedOffset: 0,
                expectedSize: 100
            )
        )
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

    func testArchiveInspectionKeepsListingsLargerThanSubprocessCaptureTail() throws {
        let entries = (0..<20_000).map { index in
            "da3_mps/python/lib/python3.13/site-packages/runtime/"
                + String(repeating: "nested/", count: 3)
                + "file-\(index).py"
        }
        XCTAssertGreaterThan(entries.joined(separator: "\n").utf8.count, 1_048_576)
        let runner = StreamingArchiveInspectionRunner(entries: entries)
        let manager = ToolchainManager(runner: runner)

        XCTAssertEqual(
            try manager.test_inspectArchiveEntries(zipURL: URL(fileURLWithPath: "/tmp/core.zip")),
            entries
        )
    }

    func testArchiveInspectionFindsSymlinkOutsideCapturedMetadataTail() throws {
        let runner = StreamingArchiveInspectionRunner(
            entries: ["bin/colmap"],
            metadataLines: [
                "lrwxr-xr-x  3.0 unx  12 bx  12 stor 01-Jan-26 00:00 bin/escape",
                "-rwxr-xr-x  3.0 unx 100 bx 100 defN 01-Jan-26 00:00 bin/colmap",
            ]
        )
        let manager = ToolchainManager(runner: runner)

        XCTAssertThrowsError(
            try manager.test_inspectArchiveEntries(zipURL: URL(fileURLWithPath: "/tmp/core.zip"))
        ) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain, got \(error)")
            }
            XCTAssertTrue(message.contains("symbolic link"))
        }
    }

    func testArchiveInspectionRejectsExcessiveEntryCount() throws {
        let runner = StreamingArchiveInspectionRunner(
            entries: (0...250_000).map { "runtime/file-\($0)" }
        )
        let manager = ToolchainManager(runner: runner)

        XCTAssertThrowsError(
            try manager.test_inspectArchiveEntries(zipURL: URL(fileURLWithPath: "/tmp/core.zip"))
        ) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain, got \(error)")
            }
            XCTAssertTrue(message.contains("inspection limit"))
        }
    }

    func testCriticalFileHashesAreEnforced() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("bin/colmap")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("colmap".utf8).write(to: executable)

        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []), urlSession: makeSession())
        let expected = try manager.test_sha256Hex(url: executable)
        XCTAssertNoThrow(try manager.test_validateCriticalFileHashes(["bin/colmap": expected], root: root))
        XCTAssertThrowsError(
            try manager.test_validateCriticalFileHashes(
                ["bin/colmap": String(repeating: "0", count: 64)],
                root: root
            )
        )
    }

    func testReceiptlessSchema1CacheIsRejected() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ToolchainFixtureBuilder.createToolchain(at: root)
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1"
        )
        try manager.saveInstallState(
            .init(
                schemaVersion: 1,
                installedArtifacts: [
                    "macos-arm64-core": String(repeating: "a", count: 64),
                    "macos-arm64-models": String(repeating: "b", count: 64),
                ]
            ),
            root: root
        )
        let key = Curve25519.Signing.PrivateKey()

        XCTAssertThrowsError(
            try manager.test_validateSignedReceipt(
                root: root,
                publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
                request: ToolchainCapabilityRequest(capabilities: [.da3Base, .da3Small])
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

        let corePaths = Self.coreFixtureContents.sorted()
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
                    "geometry-da3-small": String(repeating: "c", count: 64),
                ],
                installedCapabilities: Array(ToolchainManager.coreCapabilities).sorted() + [
                    ToolchainCapability.da3Base.rawValue,
                    ToolchainCapability.da3Small.rawValue,
                ],
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

    func testSignedReceiptRejectsUndeclaredCachedEntries() throws {
        for kind in ["file", "directory"] {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let manager = ToolchainManager(
                runner: MockSubprocessRunner(scripts: []),
                urlSession: makeSession(),
                appVersion: "0.2.0-beta.1"
            )
            let signed = try makeSignedCachedFixture(at: root, manager: manager)

            XCTAssertNoThrow(try manager.test_validateSignedReceipt(
                root: root,
                publicKeyBase64: signed.publicKey,
                request: .init(capabilities: [.da3Base, .da3Small])
            ))

            let unsigned = root.appendingPathComponent("unsigned/\(kind)")
            if kind == "file" {
                try FileManager.default.createDirectory(
                    at: unsigned.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("unsigned payload".utf8).write(to: unsigned)
            } else {
                try FileManager.default.createDirectory(at: unsigned, withIntermediateDirectories: true)
            }

            XCTAssertThrowsError(try manager.test_validateSignedReceipt(
                root: root,
                publicKeyBase64: signed.publicKey,
                request: .init(capabilities: [.da3Base, .da3Small])
            ), "Expected undeclared cached \(kind) to be rejected")
        }
    }

    func testSignedReceiptRejectsDeclaredSymlink() throws {
        let root = try TestFileBuilder.makeTempDir()
        let outside = try TestFileBuilder.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1"
        )
        let relativePath = "share/NOTICE.txt"
        let signed = try makeSignedCachedFixture(
            at: root,
            manager: manager,
            additionalCoreFiles: [relativePath: Data("signed notice".utf8)]
        )
        let declaredFile = root.appendingPathComponent(relativePath)
        let outsideFile = outside.appendingPathComponent("NOTICE.txt")
        try Data("signed notice".utf8).write(to: outsideFile)
        try FileManager.default.removeItem(at: declaredFile)
        try FileManager.default.createSymbolicLink(at: declaredFile, withDestinationURL: outsideFile)

        XCTAssertThrowsError(try manager.test_validateSignedReceipt(
            root: root,
            publicKeyBase64: signed.publicKey,
            request: .init(capabilities: [.da3Base, .da3Small])
        ))
    }

    func testSignedReceiptRejectsDeclaredSpecialFile() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1"
        )
        let relativePath = "share/runtime.pipe"
        let signed = try makeSignedCachedFixture(
            at: root,
            manager: manager,
            additionalCoreFiles: [relativePath: Data("placeholder".utf8)]
        )
        let declaredFile = root.appendingPathComponent(relativePath)
        try FileManager.default.removeItem(at: declaredFile)
        let result = declaredFile.path.withCString { mkfifo($0, mode_t(0o600)) }
        XCTAssertEqual(result, 0)

        XCTAssertThrowsError(try manager.test_validateSignedReceipt(
            root: root,
            publicKeyBase64: signed.publicKey,
            request: .init(capabilities: [.da3Base, .da3Small])
        ))
    }

    func testSignedReceiptRejectsMultiplyLinkedDeclaredFile() throws {
        let root = try TestFileBuilder.makeTempDir()
        let outside = try TestFileBuilder.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1"
        )
        let signed = try makeSignedCachedFixture(at: root, manager: manager)
        try FileManager.default.linkItem(
            at: signed.fixture.colmap,
            to: outside.appendingPathComponent("colmap-hardlink")
        )

        XCTAssertThrowsError(try manager.test_validateSignedReceipt(
            root: root,
            publicKeyBase64: signed.publicKey,
            request: .init(capabilities: [.da3Base, .da3Small])
        ))
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
            appVersion: "0.2.0-beta.1",
            installationRoot: toolchainsRoot
        )

        let corePaths = Self.coreFixtureContents.sorted()
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
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            installationRoot: parent
        )

        let replacement = Task.detached {
            try await manager.installToolchainAtomically(
                versionedRoot: versionedRoot,
                requiredCapabilities: [.da3Base, .da3Small],
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

    func testAtomicInstallRejectsUndeclaredCachedFileBeforeSeeding() async throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let sourceRoot = parent.appendingPathComponent("source", isDirectory: true)
        let versionedRoot = parent.appendingPathComponent("2.0.0", isDirectory: true)
        let destinationFixture = try ToolchainFixtureBuilder.createToolchain(at: versionedRoot)
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: validationScripts(for: destinationFixture)),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: parent
        )
        _ = try makeSignedCachedFixture(at: sourceRoot, manager: manager)
        try Data("unsigned payload".utf8).write(to: sourceRoot.appendingPathComponent("unsigned-tool"))

        let install = Task.detached {
            try await manager.installToolchainAtomically(
                versionedRoot: versionedRoot,
                requiredCapabilities: [.da3Base, .da3Small],
                seedFromExistingRoot: sourceRoot,
                onProgress: { _, _ in },
                installInto: { _ in }
            )
        }
        do {
            _ = try await install.value
            XCTFail("Expected unsigned cached file to be rejected before seeding")
        } catch {
            // Expected.
        }
    }

    func testDownloadManifestPreservesMissingReleaseStatusWithoutRetrying() async {
        for expectedStatus in [404, 410] {
            let token = UUID().uuidString
            let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
            let requests = LockedCounter()
            MockURLProtocol.register(token: token) { request in
                _ = requests.increment()
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: expectedStatus,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data())
            }

            let manager = ToolchainManager(
                runner: MockSubprocessRunner(scripts: []),
                urlSession: makeSession()
            )
            await XCTAssertThrowsErrorAsync({
                _ = try await manager.downloadManifest(url: manifestURL)
            }, errorHandler: { error in
                guard case let ToolchainManager.ToolchainError.manifestHTTPFailure(statusCode, resourceURL) = error else {
                    return XCTFail("Expected manifestHTTPFailure error, got \(error)")
                }
                XCTAssertEqual(statusCode, expectedStatus)
                XCTAssertEqual(resourceURL, manifestURL)
            })
            XCTAssertEqual(requests.current(), 1)
            MockURLProtocol.unregister(token: token)
        }
    }

    func testDownloadManifestRetriesTransientHTTPFailure() async throws {
        let signed = try minimalSignedManifest()
        let token = UUID().uuidString
        let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
        let requests = LockedCounter()
        MockURLProtocol.register(token: token) { request in
            let attempt = requests.increment()
            let statusCode = attempt < 3 ? 503 : 200
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, statusCode == 200 ? signed.data : Data())
        }
        defer { MockURLProtocol.unregister(token: token) }

        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession()
        )

        let manifest = try await manager.downloadManifest(url: manifestURL)

        XCTAssertEqual(manifest.version, signed.manifest.version)
        XCTAssertEqual(requests.current(), 3)
    }

    func testManifestHTTPRetryAndOfflineFallbackPolicy() {
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession()
        )
        let resourceURL = URL(string: "https://example.com/manifest.json")!

        for statusCode in [408, 429, 500, 503, 599] {
            XCTAssertTrue(
                manager.isTransientRetryable(
                    ToolchainManager.ToolchainError.manifestHTTPFailure(
                        statusCode: statusCode,
                        resourceURL: resourceURL
                    )
                ),
                "HTTP \(statusCode) should be retried"
            )
        }
        for statusCode in [400, 404, 410, 499] {
            let error = ToolchainManager.ToolchainError.manifestHTTPFailure(
                statusCode: statusCode,
                resourceURL: resourceURL
            )
            XCTAssertFalse(manager.isTransientRetryable(error), "HTTP \(statusCode) must not be retried")
            XCTAssertTrue(manager.shouldAttemptOfflineFallback(forManifestError: error))
        }
    }

    func testOfflineFallbackReportsRejectedCachedToolchainInsteadOfOnlyNetworkFailure() async throws {
        let installationRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: installationRoot) }
        let versionedRoot = installationRoot.appendingPathComponent("2.0.0", isDirectory: true)
        let token = UUID().uuidString
        let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            localToolchainRoot: nil,
            installationRoot: installationRoot
        )
        let signed = try makeSignedCachedFixture(at: versionedRoot, manager: manager)
        try Data("undeclared bytecode".utf8).write(
            to: versionedRoot.appendingPathComponent("da3_mps/python/runtime.pyc")
        )
        MockURLProtocol.register(token: token) { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 404,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        defer { MockURLProtocol.unregister(token: token) }

        await XCTAssertThrowsErrorAsync({
            _ = try await manager.ensureToolchain(
                manifestURL: manifestURL,
                publicKeyBase64: signed.publicKey,
                request: .init(capabilities: [.da3Base, .da3Small]),
                onProgress: { _, _ in }
            )
        }, errorHandler: { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected invalidToolchain, got \(error)")
            }
            XCTAssertTrue(message.contains("cached tools could not be verified"))
            XCTAssertTrue(message.contains("undeclared file"))
            XCTAssertTrue(message.contains("da3_mps/python/runtime.pyc"))
        })
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
                    request: ToolchainCapabilityRequest(capabilities: [.da3Base, .da3Small]),
                    onProgress: { _, _ in }
                )
            }, errorHandler: { error in
                guard case ToolchainManager.ToolchainError.invalidManifest = error else {
                    return XCTFail("Expected invalidManifest error, got \(error)")
                }
            })
        }
    }

    func testDownloadManifestAcceptsExactlySixteenMiB() async throws {
        let maximumBytes = 16 * 1_024 * 1_024
        let signed = try minimalSignedManifest()
        var data = signed.data
        data.append(Data(repeating: 0x20, count: maximumBytes - data.count))
        XCTAssertEqual(data.count, maximumBytes)
        let responseData = data

        let token = UUID().uuidString
        let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
        MockURLProtocol.register(token: token) { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Length": "\(maximumBytes)"]
                )!,
                responseData
            )
        }
        defer { MockURLProtocol.unregister(token: token) }

        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession()
        )

        let manifest = try await manager.downloadManifest(url: manifestURL)

        XCTAssertEqual(manifest.version, signed.manifest.version)
    }

    func testDownloadManifestRejectsOversizedContentLengthBeforeReadingBody() async throws {
        let maximumBytes = 16 * 1_024 * 1_024
        let signed = try minimalSignedManifest()
        let token = UUID().uuidString
        let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
        let requests = LockedCounter()
        MockURLProtocol.register(token: token) { request in
            _ = requests.increment()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Length": "\(maximumBytes + 1)"]
                )!,
                signed.data
            )
        }
        defer { MockURLProtocol.unregister(token: token) }

        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession()
        )

        await XCTAssertThrowsErrorAsync({
            try await manager.downloadManifest(url: manifestURL)
        }, errorHandler: { error in
            guard case ToolchainManager.ToolchainError.manifestTooLarge(maximumBytes) = error else {
                return XCTFail("Expected manifestTooLarge, got \(error)")
            }
            XCTAssertEqual(maximumBytes, 16 * 1_024 * 1_024)
        })
        XCTAssertEqual(requests.current(), 1)
    }

    func testDownloadManifestRejectsStreamingOverflowWithoutContentLength() async throws {
        let maximumBytes = 16 * 1_024 * 1_024
        let signed = try minimalSignedManifest()
        var data = signed.data
        data.append(Data(repeating: 0x20, count: maximumBytes + 1 - data.count))
        XCTAssertEqual(data.count, maximumBytes + 1)
        let responseData = data

        let token = UUID().uuidString
        let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
        let requests = LockedCounter()
        MockURLProtocol.register(token: token) { request in
            _ = requests.increment()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                responseData
            )
        }
        defer { MockURLProtocol.unregister(token: token) }

        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession()
        )

        await XCTAssertThrowsErrorAsync({
            try await manager.downloadManifest(url: manifestURL)
        }, errorHandler: { error in
            guard case ToolchainManager.ToolchainError.manifestTooLarge(maximumBytes) = error else {
                return XCTFail("Expected manifestTooLarge, got \(error)")
            }
            XCTAssertEqual(maximumBytes, 16 * 1_024 * 1_024)
        })
        XCTAssertEqual(requests.current(), 1)
    }

    func testDownloadManifestDecodesNormalResponseWithoutContentLength() async throws {
        let signed = try minimalSignedManifest()
        let token = UUID().uuidString
        let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
        MockURLProtocol.register(token: token) { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                signed.data
            )
        }
        defer { MockURLProtocol.unregister(token: token) }

        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession()
        )

        let manifest = try await manager.downloadManifest(url: manifestURL)

        XCTAssertEqual(manifest.version, signed.manifest.version)
    }

    func testInvalidManifestNeverUsesOfflineFallback() {
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession()
        )

        XCTAssertFalse(
            manager.shouldAttemptOfflineFallback(
                forManifestError: ToolchainManager.ToolchainError.invalidManifest
            )
        )
    }

    func testSignedSchema1ManifestsNeverDownloadComponents() async throws {
        try await withEnvironmentAsync(["EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": nil]) {
            for componentNames in [["macos-arm64"], ["macos-arm64-core", "macos-arm64-models"]] {
                let token = UUID().uuidString
                let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
                let componentURLs = componentNames.map {
                    tokenizedURL("https://example.com/\($0).zip", token: token)
                }
                let signed = try signedSchema1Manifest(
                    version: "1.2.3",
                    componentNames: componentNames,
                    componentURLs: componentURLs
                )
                let requests = LockedMessages()

                MockURLProtocol.register(token: token) { request in
                    requests.append(request.url?.absoluteString ?? "missing-url")
                    let response = HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                    if request.url == manifestURL {
                        return (response, signed.data)
                    }
                    return (response, Data("component".utf8))
                }
                defer { MockURLProtocol.unregister(token: token) }

                let root = try TestFileBuilder.makeTempDir()
                defer { try? FileManager.default.removeItem(at: root) }
                let manager = ToolchainManager(
                    runner: MockSubprocessRunner(scripts: []),
                    urlSession: makeSession(),
                    appVersion: "0.2.0-beta.1",
                    localToolchainRoot: nil,
                    installationRoot: root
                )

                await XCTAssertThrowsErrorAsync({
                    _ = try await manager.ensureToolchain(
                        manifestURL: manifestURL,
                        publicKeyBase64: signed.publicKey,
                        request: ToolchainCapabilityRequest(capabilities: [.da3Base, .da3Small]),
                        onProgress: { _, _ in }
                    )
                }, errorHandler: { error in
                    guard case ToolchainManager.ToolchainError.invalidManifest = error else {
                        return XCTFail("Expected invalidManifest, got \(error)")
                    }
                })
                XCTAssertEqual(
                    requests.all(),
                    [manifestURL.absoluteString],
                    "Schema-1 manifest downloaded a component: \(componentNames)"
                )
            }
        }
    }

    func testSignedUnsupportedSchemaAndToolchainAPINeverDownloadComponents() async throws {
        try await withEnvironmentAsync(["EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": nil]) {
            for (schemaVersion, toolchainAPI) in [(3, 2), (2, 3)] {
                let token = UUID().uuidString
                let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
                let signed = try signedUnsupportedV2Manifest(
                    schemaVersion: schemaVersion,
                    toolchainAPI: toolchainAPI,
                    token: token
                )
                XCTAssertTrue(signed.manifest.verifying(publicKeyBase64: signed.publicKey))
                let requests = LockedMessages()

                MockURLProtocol.register(token: token) { request in
                    requests.append(request.url?.absoluteString ?? "missing-url")
                    let response = HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                    return request.url == manifestURL
                        ? (response, signed.data)
                        : (response, Data("component".utf8))
                }
                defer { MockURLProtocol.unregister(token: token) }

                let root = try TestFileBuilder.makeTempDir()
                defer { try? FileManager.default.removeItem(at: root) }
                let manager = ToolchainManager(
                    runner: MockSubprocessRunner(scripts: []),
                    urlSession: makeSession(),
                    appVersion: "0.2.0-beta.1",
                    localToolchainRoot: nil,
                    installationRoot: root
                )

                await XCTAssertThrowsErrorAsync({
                    _ = try await manager.ensureToolchain(
                        manifestURL: manifestURL,
                        publicKeyBase64: signed.publicKey,
                        request: ToolchainCapabilityRequest(capabilities: [.da3Base, .da3Small]),
                        onProgress: { _, _ in }
                    )
                }, errorHandler: { error in
                    guard case ToolchainManager.ToolchainError.invalidManifest = error else {
                        return XCTFail("Expected invalidManifest, got \(error)")
                    }
                })
                XCTAssertEqual(requests.all(), [manifestURL.absoluteString])
            }
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
            let criticalCorePaths = ToolchainManager.criticalCoreFiles(in: Self.coreFixtureContents).sorted()
            let criticalCoreHashes = try Dictionary(uniqueKeysWithValues: criticalCorePaths.map { path in
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
                    .init(name: "macos-arm64-core", capabilities: ["runtime.core", "geometry.colmap", "geometry.da3.runtime", "training.msplat"], url: coreURL.absoluteString, sha256: componentHash(coreData), sizeBytes: UInt64(coreData.count), contents: Self.coreFixtureContents, criticalFileHashes: criticalCoreHashes, dependencies: [], requirement: .required),
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
            XCTAssertTrue(
                Set([ToolchainCapability.da3Base, .da3Small].map(\.rawValue))
                    .isSubset(of: Set(expandedReceipt.installedCapabilities))
            )

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

        let artifact = testComponent(
            name: "geometry-da3-base",
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

        XCTAssertTrue(allMessages.contains("Verified download integrity (geometry-da3-base)"))
        XCTAssertTrue(allMessages.contains("Unpacking tools"))
        XCTAssertTrue(allMessages.contains("Unpacking tools: found 1/2 expected files"))
    }

    func testEnsureArtifactSucceedsWhenExpectedContentsPresent() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let token = UUID().uuidString
        let artifactURL = tokenizedURL("https://example.com/models.zip", token: token)
        let zipData = Data("zip-bytes".utf8)
        let zipHash = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()

        let artifact = testComponent(
            name: "geometry-da3-base",
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
        XCTAssertTrue(allMessages.contains("Verified download integrity (geometry-da3-base)"))
        XCTAssertTrue(allMessages.contains("Unpacking tools: found 1/1 expected files"))
    }

    func testEnsureArtifactResumesPersistedPartialAfterRelaunch() async throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let firstStagingRoot = parent.appendingPathComponent("2.0.0.staging-first", isDirectory: true)
        let cancelledStagingRoot = parent.appendingPathComponent("2.0.0.staging-cancelled", isDirectory: true)
        let relaunchedStagingRoot = parent.appendingPathComponent("2.0.0.staging-second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstStagingRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cancelledStagingRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relaunchedStagingRoot, withIntermediateDirectories: true)

        let token = UUID().uuidString
        let artifactURL = tokenizedURL("https://example.com/models.zip", token: token)
        let zipData = Data("zip-bytes".utf8)
        let prefix = zipData.prefix(4)
        let suffix = zipData.dropFirst(prefix.count)
        let zipHash = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        let requestCounter = LockedCounter()
        let ranges = LockedMessages()
        let encodings = LockedMessages()

        let artifact = testComponent(
            name: "geometry-da3-base",
            url: artifactURL.absoluteString,
            sha256: zipHash,
            sizeBytes: UInt64(zipData.count),
            contents: ["da3_mps/models/DA3-BASE/model.safetensors"]
        )

        MockURLProtocol.register(token: token) { request in
            ranges.append(request.value(forHTTPHeaderField: "Range") ?? "none")
            encodings.append(request.value(forHTTPHeaderField: "Accept-Encoding") ?? "none")
            switch requestCounter.increment() {
            case 1:
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(prefix)
                )
            case 2, 3:
                throw URLError(.timedOut)
            case 4:
                let end = zipData.count - 1
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 206,
                        httpVersion: nil,
                        headerFields: [
                            "Accept-Ranges": "bytes",
                            "Content-Length": String(suffix.count),
                            "Content-Range": "bytes \(prefix.count)-\(end)/\(zipData.count)",
                        ]
                    )!,
                    Data(suffix)
                )
            default:
                throw URLError(.badServerResponse)
            }
        }
        defer { MockURLProtocol.unregister(token: token) }

        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/usr/bin/unzip",
                argsPrefix: ["-o"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { @Sendable args in
                    guard let destinationIndex = args.firstIndex(of: "-d"),
                          args.indices.contains(destinationIndex + 1) else { return }
                    let destination = URL(fileURLWithPath: args[destinationIndex + 1], isDirectory: true)
                    let expectedFile = destination.appendingPathComponent("da3_mps/models/DA3-BASE/model.safetensors")
                    try? FileManager.default.createDirectory(
                        at: expectedFile.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    FileManager.default.createFile(atPath: expectedFile.path, contents: Data([0x00]))
                }
            )
        ])
        let manager = ToolchainManager(runner: runner, urlSession: makeSession())

        await XCTAssertThrowsErrorAsync({
            try await manager.test_ensureArtifact(artifact, root: firstStagingRoot) { _, _ in }
        })
        XCTAssertEqual(requestCounter.current(), 3)
        let retainedFiles = FileManager.default.enumerator(atPath: parent.path)?.allObjects.compactMap { $0 as? String } ?? []
        XCTAssertTrue(retainedFiles.contains(where: { $0.hasSuffix(".partial") }), "Retained files: \(retainedFiles)")

        let cancelledDownload = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await manager.test_ensureArtifact(artifact, root: cancelledStagingRoot) { _, _ in }
        }
        do {
            try await cancelledDownload.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // The partial belongs to the verified artifact identity and remains resumable.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertEqual(requestCounter.current(), 3)

        do {
            try await manager.test_ensureArtifact(artifact, root: relaunchedStagingRoot) { _, _ in }
        } catch {
            XCTFail("Resume failed after \(requestCounter.current()) requests \(ranges.all()): \(error)")
            return
        }

        XCTAssertEqual(requestCounter.current(), 4)
        XCTAssertEqual(ranges.all(), ["none", "bytes=4-", "bytes=4-", "bytes=4-"])
        XCTAssertEqual(encodings.all(), Array(repeating: "identity", count: 4))
    }

    func testPartialDownloadIdentityIncludesURLHashAndVersion() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []), urlSession: makeSession())
        let firstURL = URL(string: "https://example.com/first.zip")!
        let secondURL = URL(string: "https://example.com/second.zip")!
        let firstHash = String(repeating: "a", count: 64)
        let secondHash = String(repeating: "b", count: 64)
        let firstRoot = parent.appendingPathComponent("2.0.0.staging-first", isDirectory: true)
        let sameVersionRoot = parent.appendingPathComponent("2.0.0.staging-second", isDirectory: true)
        let nextVersionRoot = parent.appendingPathComponent("2.0.1.staging-first", isDirectory: true)
        for root in [firstRoot, sameVersionRoot, nextVersionRoot] {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        let firstArtifact = testComponent(
            name: "geometry-da3-base",
            url: firstURL.absoluteString,
            sha256: firstHash,
            sizeBytes: 8,
            contents: ["model.safetensors"]
        )
        let firstPartial = try manager.preparePartialDownload(
            artifact: firstArtifact,
            url: firstURL,
            installationRoot: firstRoot
        )
        try Data([0x01]).write(to: firstPartial)

        var changedURLArtifact = firstArtifact
        changedURLArtifact.url = secondURL.absoluteString
        let changedURLPartial = try manager.preparePartialDownload(
            artifact: changedURLArtifact,
            url: secondURL,
            installationRoot: sameVersionRoot
        )
        XCTAssertNotEqual(firstPartial.path, changedURLPartial.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPartial.path))
        try Data([0x02]).write(to: changedURLPartial)

        var changedHashArtifact = changedURLArtifact
        changedHashArtifact.sha256 = secondHash
        let changedHashPartial = try manager.preparePartialDownload(
            artifact: changedHashArtifact,
            url: secondURL,
            installationRoot: sameVersionRoot
        )
        XCTAssertNotEqual(changedURLPartial.path, changedHashPartial.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: changedURLPartial.path))
        try Data([0x03]).write(to: changedHashPartial)

        let changedVersionPartial = try manager.preparePartialDownload(
            artifact: changedHashArtifact,
            url: secondURL,
            installationRoot: nextVersionRoot
        )
        XCTAssertNotEqual(changedHashPartial.path, changedVersionPartial.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: changedHashPartial.path))
        try Data(repeating: 0x04, count: 9).write(to: changedVersionPartial)

        let cleanedOversizedPartial = try manager.preparePartialDownload(
            artifact: changedHashArtifact,
            url: secondURL,
            installationRoot: nextVersionRoot
        )
        XCTAssertEqual(cleanedOversizedPartial.path, changedVersionPartial.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanedOversizedPartial.path))
    }

    func testDiskPreflightCreditsOnlyReusablePartialBytes() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("2.0.0.staging-test", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let completeData = Data("0123456789".utf8)
        let hash = SHA256.hash(data: completeData).map { String(format: "%02x", $0) }.joined()
        let component = ToolchainManifest.Component(
            name: "geometry-da3-base",
            capabilities: ["geometry.da3.base"],
            url: "https://example.com/base.zip",
            sha256: hash,
            sizeBytes: UInt64(completeData.count),
            expandedSizeBytes: 100,
            contents: ["model.safetensors"],
            criticalFileHashes: [:],
            dependencies: ["macos-arm64-core"],
            requirement: .required
        )
        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []), urlSession: makeSession())
        let partial = try manager.preparePartialDownload(
            artifact: component,
            url: URL(string: component.url)!,
            installationRoot: root
        )
        let headroom: UInt64 = 64 * 1_024 * 1_024

        try completeData.prefix(4).write(to: partial)
        XCTAssertEqual(
            try manager.requiredDiskBytes(for: [component], at: root),
            headroom + 100 + UInt64(completeData.count - 4)
        )

        try completeData.write(to: partial)
        XCTAssertEqual(
            try manager.requiredDiskBytes(for: [component], at: root),
            headroom + 100
        )

        try Data(repeating: 0xff, count: completeData.count).write(to: partial)
        XCTAssertEqual(
            try manager.requiredDiskBytes(for: [component], at: root),
            headroom + 100 + UInt64(completeData.count)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))

        let seedRoot = parent.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: seedRoot, withIntermediateDirectories: true)
        try Data(repeating: 0x01, count: 7).write(to: seedRoot.appendingPathComponent("installed.bin"))
        XCTAssertEqual(
            try manager.requiredDiskBytes(
                for: [component],
                at: root,
                seedFromExistingRoot: seedRoot
            ),
            headroom + 7 + 100 + UInt64(completeData.count)
        )
    }

    func testPreflightAndStagingShareAParentDownloadCache() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []), urlSession: makeSession())
        let artifact = testComponent(
            name: "geometry-da3-small",
            url: "https://example.com/small.zip",
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 10,
            contents: ["model.safetensors"]
        )
        let canonical = parent.appendingPathComponent("2.0.0", isDirectory: true)
        let staging = parent.appendingPathComponent("2.0.0.staging-test", isDirectory: true)
        let url = try XCTUnwrap(URL(string: artifact.url))

        let preflightPartial = try manager.preparePartialDownload(
            artifact: artifact,
            url: url,
            installationRoot: canonical
        )
        let stagingPartial = try manager.preparePartialDownload(
            artifact: artifact,
            url: url,
            installationRoot: staging
        )

        XCTAssertEqual(preflightPartial, stagingPartial)
        XCTAssertFalse(FileManager.default.fileExists(atPath: canonical.path))
        XCTAssertTrue(preflightPartial.path.hasPrefix(
            parent.appendingPathComponent(".easysplat-downloads", isDirectory: true).path + "/"
        ))
    }

    func testRangeIgnoringServerRestartsFromItsFullResponse() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let token = UUID().uuidString
        let artifactURL = tokenizedURL("https://example.com/models.zip", token: token)
        let zipData = Data("zip-bytes".utf8)
        let zipHash = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        let artifact = testComponent(
            name: "geometry-da3-base",
            url: artifactURL.absoluteString,
            sha256: zipHash,
            sizeBytes: UInt64(zipData.count),
            contents: ["model.safetensors"]
        )
        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []), urlSession: makeSession())
        let partialURL = try manager.preparePartialDownload(
            artifact: artifact,
            url: artifactURL,
            installationRoot: root
        )
        try zipData.prefix(4).write(to: partialURL)
        let ranges = LockedMessages()

        MockURLProtocol.register(token: token) { request in
            ranges.append(request.value(forHTTPHeaderField: "Range") ?? "none")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                zipData
            )
        }
        defer { MockURLProtocol.unregister(token: token) }

        let destination = root.appendingPathComponent("verified.zip")
        try await manager.downloadVerifiedArtifact(
            artifact,
            from: artifactURL,
            to: destination,
            installationRoot: root,
            label: "Downloading tools",
            onProgress: { _, _ in }
        )

        XCTAssertEqual(ranges.all(), ["bytes=4-"])
        XCTAssertEqual(try Data(contentsOf: destination), zipData)
    }

    func testCorruptPersistedFullDownloadIsReplacedWithoutAResumeRequest() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let token = UUID().uuidString
        let artifactURL = tokenizedURL("https://example.com/models.zip", token: token)
        let zipData = Data("zip-bytes".utf8)
        let zipHash = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        let artifact = testComponent(
            name: "geometry-da3-base",
            url: artifactURL.absoluteString,
            sha256: zipHash,
            sizeBytes: UInt64(zipData.count),
            contents: ["model.safetensors"]
        )
        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []), urlSession: makeSession())
        let partialURL = try manager.preparePartialDownload(
            artifact: artifact,
            url: artifactURL,
            installationRoot: root
        )
        try Data("bad-bytes".utf8).write(to: partialURL)
        let ranges = LockedMessages()

        MockURLProtocol.register(token: token) { request in
            ranges.append(request.value(forHTTPHeaderField: "Range") ?? "none")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                zipData
            )
        }
        defer { MockURLProtocol.unregister(token: token) }

        let destination = root.appendingPathComponent("verified.zip")
        try await manager.downloadVerifiedArtifact(
            artifact,
            from: artifactURL,
            to: destination,
            installationRoot: root,
            label: "Downloading tools",
            onProgress: { _, _ in }
        )

        XCTAssertEqual(ranges.all(), ["none"])
        XCTAssertEqual(try Data(contentsOf: destination), zipData)
    }

    func testInvalidContentRangeIsDiscardedBeforeRetry() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let token = UUID().uuidString
        let artifactURL = tokenizedURL("https://example.com/models.zip", token: token)
        let zipData = Data("zip-bytes".utf8)
        let zipHash = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        let artifact = testComponent(
            name: "geometry-da3-base",
            url: artifactURL.absoluteString,
            sha256: zipHash,
            sizeBytes: UInt64(zipData.count),
            contents: ["model.safetensors"]
        )
        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []), urlSession: makeSession())
        let partialURL = try manager.preparePartialDownload(
            artifact: artifact,
            url: artifactURL,
            installationRoot: root
        )
        try zipData.prefix(4).write(to: partialURL)
        let requestCounter = LockedCounter()
        let ranges = LockedMessages()

        MockURLProtocol.register(token: token) { request in
            ranges.append(request.value(forHTTPHeaderField: "Range") ?? "none")
            if requestCounter.increment() == 1 {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 206,
                        httpVersion: nil,
                        headerFields: ["Content-Range": "bytes 3-8/9"]
                    )!,
                    Data(zipData.dropFirst(4))
                )
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                zipData
            )
        }
        defer { MockURLProtocol.unregister(token: token) }

        let destination = root.appendingPathComponent("verified.zip")
        try await manager.downloadVerifiedArtifact(
            artifact,
            from: artifactURL,
            to: destination,
            installationRoot: root,
            label: "Downloading tools",
            onProgress: { _, _ in }
        )

        XCTAssertEqual(ranges.all(), ["bytes=4-", "none"])
        XCTAssertEqual(try Data(contentsOf: destination), zipData)
    }

    func testCorruptCompletedPartialIsRemovedBeforeFreshDownload() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let token = UUID().uuidString
        let artifactURL = tokenizedURL("https://example.com/models.zip", token: token)
        let zipData = Data("zip-bytes".utf8)
        let corruptPrefix = Data("bad-".utf8)
        let zipHash = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        let artifact = testComponent(
            name: "geometry-da3-base",
            url: artifactURL.absoluteString,
            sha256: zipHash,
            sizeBytes: UInt64(zipData.count),
            contents: ["model.safetensors"]
        )
        let requestCounter = LockedCounter()
        let ranges = LockedMessages()

        MockURLProtocol.register(token: token) { request in
            ranges.append(request.value(forHTTPHeaderField: "Range") ?? "none")
            switch requestCounter.increment() {
            case 1:
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    corruptPrefix
                )
            case 2, 3:
                throw URLError(.timedOut)
            case 4:
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 206,
                        httpVersion: nil,
                        headerFields: ["Content-Range": "bytes 4-8/9"]
                    )!,
                    Data(zipData.dropFirst(4))
                )
            case 5:
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    zipData
                )
            default:
                throw URLError(.badServerResponse)
            }
        }
        defer { MockURLProtocol.unregister(token: token) }

        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []), urlSession: makeSession())
        let destination = root.appendingPathComponent("verified.zip")
        await XCTAssertThrowsErrorAsync({
            try await manager.downloadVerifiedArtifact(
                artifact,
                from: artifactURL,
                to: destination,
                installationRoot: root,
                label: "Downloading tools",
                onProgress: { _, _ in }
            )
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try await manager.downloadVerifiedArtifact(
            artifact,
            from: artifactURL,
            to: destination,
            installationRoot: root,
            label: "Downloading tools",
            onProgress: { _, _ in }
        )

        XCTAssertEqual(ranges.all(), ["none", "bytes=4-", "bytes=4-", "bytes=4-", "none"])
        XCTAssertEqual(try Data(contentsOf: destination), zipData)
    }

    func testEnsureArtifactRetriesTransientDownloadFailureAndSucceeds() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let token = UUID().uuidString
        let artifactURL = tokenizedURL("https://example.com/models.zip", token: token)
        let zipData = Data("zip-bytes".utf8)
        let zipHash = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        let requestCounter = LockedCounter()

        let artifact = testComponent(
            name: "geometry-da3-base",
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

    private func testComponent(
        name: String,
        url: String,
        sha256: String,
        sizeBytes: UInt64,
        contents: [String]
    ) -> ToolchainManifest.Component {
        ToolchainManifest.Component(
            name: name,
            capabilities: ["test.component"],
            url: url,
            sha256: sha256,
            sizeBytes: sizeBytes,
            contents: contents,
            criticalFileHashes: [:],
            dependencies: [],
            requirement: .required
        )
    }

    private func makeSignedCachedFixture(
        at root: URL,
        manager: ToolchainManager,
        additionalCoreFiles: [String: Data] = [:]
    ) throws -> (fixture: ToolchainFixture, publicKey: String) {
        let fixture = try ToolchainFixtureBuilder.createToolchain(at: root)
        for (relativePath, data) in additionalCoreFiles {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }

        let coreContents = (Self.coreFixtureContents + Array(additionalCoreFiles.keys)).sorted()
        let baseContents = [
            "da3_mps/models/DA3-BASE/config.json",
            "da3_mps/models/DA3-BASE/easysplat_model_info.json",
            "da3_mps/models/DA3-BASE/model.safetensors",
        ]
        let smallContents = [
            "da3_mps/models/DA3-SMALL/config.json",
            "da3_mps/models/DA3-SMALL/easysplat_model_info.json",
            "da3_mps/models/DA3-SMALL/model.safetensors",
        ]
        func hashes(for paths: [String]) throws -> [String: String] {
            try Dictionary(uniqueKeysWithValues: paths.map { path in
                (path, try manager.test_sha256Hex(url: root.appendingPathComponent(path)))
            })
        }

        let coreCritical = ToolchainManager.criticalCoreFiles(in: coreContents).sorted()
        let unsigned = ToolchainManifest(
            schemaVersion: 2,
            toolchainAPI: 2,
            keyID: "",
            version: "2.0.0",
            publishedAt: Date(timeIntervalSince1970: 0),
            appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
            components: [
                .init(name: "macos-arm64-core", capabilities: Array(ToolchainManager.coreCapabilities), url: "https://example.com/core.zip", sha256: String(repeating: "a", count: 64), sizeBytes: 1, contents: coreContents, criticalFileHashes: try hashes(for: coreCritical), dependencies: [], requirement: .required),
                .init(name: "geometry-da3-base", capabilities: [ToolchainCapability.da3Base.rawValue], url: "https://example.com/base.zip", sha256: String(repeating: "b", count: 64), sizeBytes: 1, contents: baseContents, criticalFileHashes: try hashes(for: baseContents), dependencies: ["macos-arm64-core"], requirement: .required),
                .init(name: "geometry-da3-small", capabilities: [ToolchainCapability.da3Small.rawValue], url: "https://example.com/small.zip", sha256: String(repeating: "c", count: 64), sizeBytes: 1, contents: smallContents, criticalFileHashes: try hashes(for: smallContents), dependencies: ["macos-arm64-core"], requirement: .optional),
            ],
            signatureEd25519: ""
        )
        let signed = try signedV2Manifest(unsigned)
        try manager.saveInstallState(
            .init(
                schemaVersion: 2,
                installedArtifacts: Dictionary(
                    uniqueKeysWithValues: signed.manifest.components.map { ($0.name, $0.sha256) }
                ),
                installedCapabilities: Set(signed.manifest.components.flatMap(\.capabilities)).sorted(),
                signedManifest: signed.manifest
            ),
            root: root
        )
        return (fixture, signed.publicKey)
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
                argsPrefix: ["mapper"],
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

    private struct Schema1ArtifactForSigning: Codable {
        var name: String
        var url: String
        var sha256: String
        var sizeBytes: UInt64
        var contents: [String]
    }

    private struct Schema1ManifestForSigning: Codable {
        var version: String
        var publishedAt: Date
        var artifacts: [Schema1ArtifactForSigning]
        var signatureEd25519: String
    }

    private func signedSchema1Manifest(
        version: String,
        componentNames: [String],
        componentURLs: [URL]
    ) throws -> (publicKey: String, data: Data) {
        let payload = Data("component".utf8)
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let key = Curve25519.Signing.PrivateKey()
        var manifest = Schema1ManifestForSigning(
            version: version,
            publishedAt: Date(timeIntervalSince1970: 0),
            artifacts: zip(componentNames, componentURLs).map { pair in
                Schema1ArtifactForSigning(
                    name: pair.0,
                    url: pair.1.absoluteString,
                    sha256: hash,
                    sizeBytes: UInt64(payload.count),
                    contents: ["bin/colmap"]
                )
            },
            signatureEd25519: ""
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        manifest.signatureEd25519 = try key.signature(for: encoder.encode(manifest)).base64EncodedString()
        return (
            key.publicKey.rawRepresentation.base64EncodedString(),
            try encoder.encode(manifest)
        )
    }

    private func signedUnsupportedV2Manifest(
        schemaVersion: Int,
        toolchainAPI: Int,
        token: String
    ) throws -> (manifest: ToolchainManifest, publicKey: String, data: Data) {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        let hash = String(repeating: "a", count: 64)
        var manifest = ToolchainManifest(
            schemaVersion: schemaVersion,
            toolchainAPI: toolchainAPI,
            keyID: ToolchainManifest.keyID(publicKeyBase64: publicKey)!,
            version: "2.0.0",
            publishedAt: Date(timeIntervalSince1970: 0),
            appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
            components: [
                .init(
                    name: "macos-arm64-core",
                    capabilities: Array(ToolchainManager.coreCapabilities),
                    url: tokenizedURL("https://example.com/core.zip", token: token).absoluteString,
                    sha256: hash,
                    sizeBytes: 1,
                    contents: ["bin/colmap"],
                    criticalFileHashes: ["bin/colmap": hash],
                    dependencies: [],
                    requirement: .required
                ),
                .init(
                    name: "geometry-da3-base",
                    capabilities: [ToolchainCapability.da3Base.rawValue],
                    url: tokenizedURL("https://example.com/base.zip", token: token).absoluteString,
                    sha256: hash,
                    sizeBytes: 1,
                    contents: ["da3_mps/models/DA3-BASE/model.safetensors"],
                    criticalFileHashes: ["da3_mps/models/DA3-BASE/model.safetensors": hash],
                    dependencies: ["macos-arm64-core"],
                    requirement: .required
                ),
                .init(
                    name: "geometry-da3-small",
                    capabilities: [ToolchainCapability.da3Small.rawValue],
                    url: tokenizedURL("https://example.com/small.zip", token: token).absoluteString,
                    sha256: hash,
                    sizeBytes: 1,
                    contents: ["da3_mps/models/DA3-SMALL/model.safetensors"],
                    criticalFileHashes: ["da3_mps/models/DA3-SMALL/model.safetensors": hash],
                    dependencies: ["macos-arm64-core"],
                    requirement: .optional
                ),
            ],
            signatureEd25519: ""
        )
        manifest.signatureEd25519 = try key.signature(for: manifest.canonicalData()).base64EncodedString()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (manifest, publicKey, try encoder.encode(manifest))
    }

    private func minimalSignedManifest() throws -> (manifest: ToolchainManifest, publicKey: String, data: Data) {
        try signedV2Manifest(
            ToolchainManifest(
                schemaVersion: 2,
                toolchainAPI: 2,
                keyID: "",
                version: "2.0.0",
                publishedAt: Date(timeIntervalSince1970: 0),
                appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
                components: [],
                signatureEd25519: ""
            )
        )
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

private final class StreamingArchiveInspectionRunner: @unchecked Sendable, SubprocessRunning {
    private let entries: [String]
    private let metadataLines: [String]

    init(
        entries: [String],
        metadataLines: [String] = [
            "-rw-r--r--  3.0 unx 100 bx 100 defN 01-Jan-26 00:00 bin/colmap"
        ]
    ) {
        self.entries = entries
        self.metadataLines = metadataLines
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) throws -> SubprocessResult {
        if launchPath == "/usr/bin/zipinfo", arguments.first == "-l" {
            metadataLines.forEach(onStdout)
            return SubprocessResult(
                exitCode: 0,
                terminationReason: .exit,
                stdout: metadataLines.suffix(1).joined(separator: "\n"),
                stderr: ""
            )
        }
        if launchPath == "/usr/bin/unzip", arguments.first == "-Z1" {
            entries.forEach(onStdout)
            return SubprocessResult(
                exitCode: 0,
                terminationReason: .exit,
                stdout: entries.suffix(16).joined(separator: "\n"),
                stderr: ""
            )
        }
        throw NSError(
            domain: "StreamingArchiveInspectionRunner",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Unexpected command: \(launchPath) \(arguments)"]
        )
    }

    func runAsync(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) async throws -> SubprocessResult {
        try run(
            launchPath,
            arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            onStdout: onStdout,
            onStderr: onStderr
        )
    }
}
