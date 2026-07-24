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
        "lib/libomp.dylib",
        "msplat/build_info.json",
        "msplat/LICENSE",
        "provenance/colmap.json",
        "provenance/colmap-support.json",
        "provenance/ceres.json",
        "provenance/openimageio.json",
        "licenses/COLMAP/COPYING.txt",
        "licenses/COLMAPSupport/OpenMP-LICENSE.txt",
        "licenses/Ceres/LICENSE",
        "licenses/OpenImageIO/LICENSE.md",
        "supply-chain/components.json",
    ]

    private static let baseFixtureContents = [
        "da3_mps/bin/easysplat_da3_sfm",
        "da3_mps/python/bin/python3",
        "da3_mps/app/easysplat_da3_sfm/run.py",
        "da3_mps/vendor/depth-anything-3/src/depth_anything_3/api.py",
        "da3_mps/build_info.json",
        "da3_mps/models/DA3-BASE/config.json",
        "da3_mps/models/DA3-BASE/easysplat_model_info.json",
        "da3_mps/models/DA3-BASE/model.safetensors",
        "da3_mps/models/DA3-BASE/LICENSE",
    ]

    private static let smallFixtureContents = [
        "da3_mps/models/DA3-SMALL/config.json",
        "da3_mps/models/DA3-SMALL/easysplat_model_info.json",
        "da3_mps/models/DA3-SMALL/model.safetensors",
        "da3_mps/models/DA3-SMALL/LICENSE",
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

    private final class EmptyURLSessionDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {}

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

    func testLoadInstallStateFallsBackForMissingRequiredFieldsAndMalformedJSON() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent(".easysplat_toolchain_state.json")
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession()
        )
        let invalidDocuments = [
            #"{"installedArtifacts":{"component":"hash"},"installedCapabilities":["runtime.core"],"signedManifest":null}"#,
            #"{"schemaVersion":2,"installedCapabilities":["runtime.core"],"signedManifest":null}"#,
            #"{"schemaVersion":2,"installedArtifacts":{"component":"hash"},"signedManifest":null}"#,
            #"{"schemaVersion":2,"installedArtifacts":{},"installedCapabilities":[]"#,
        ]

        for document in invalidDocuments {
            try Data(document.utf8).write(to: stateURL, options: .atomic)

            let state = manager.loadInstallState(root: root)

            XCTAssertEqual(state.schemaVersion, ToolchainManifest.currentSchemaVersion)
            XCTAssertTrue(state.installedArtifacts.isEmpty)
            XCTAssertTrue(state.installedCapabilities.isEmpty)
            XCTAssertNil(state.signedManifest)
        }
    }

    func testSaveInstallStateAtomicallyReplacesPrivateReceiptWithoutTemporaryResidue() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession()
        )

        try manager.saveInstallState(
            .init(installedArtifacts: ["macos-arm64-core": String(repeating: "a", count: 64)]),
            root: root
        )
        try manager.saveInstallState(
            .init(installedArtifacts: ["macos-arm64-core": String(repeating: "b", count: 64)]),
            root: root
        )

        let receipt = root.appendingPathComponent(".easysplat_toolchain_state.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: receipt.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let loaded = manager.loadInstallState(root: root)
        XCTAssertEqual(loaded.schemaVersion, ToolchainManifest.currentSchemaVersion)
        XCTAssertEqual(
            loaded.installedArtifacts["macos-arm64-core"],
            String(repeating: "b", count: 64)
        )
        XCTAssertTrue(loaded.installedCapabilities.isEmpty)
        XCTAssertNil(loaded.signedManifest)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(),
            [".easysplat_toolchain_state.json"]
        )
    }

    func testLoadInstallStateAcceptsReceiptAtSixteenMiBEnvelopeLimit() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent(".easysplat_toolchain_state.json")
        let data = try installStateData(exactly: 16 * 1_024 * 1_024)
        XCTAssertEqual(data.count, 16 * 1_024 * 1_024)
        try data.write(to: stateURL)
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession()
        )

        XCTAssertFalse(manager.loadInstallState(root: root).installedArtifacts.isEmpty)
    }

    func testLoadInstallStateIgnoresReceiptOneByteAboveSixteenMiBEnvelopeLimit() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent(".easysplat_toolchain_state.json")
        let data = try installStateData(exactly: 16 * 1_024 * 1_024 + 1)
        XCTAssertEqual(data.count, 16 * 1_024 * 1_024 + 1)
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
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: session
        )
        let partialFile = try XCTUnwrap(
            manager.openPartialDownloadFile(at: partialURL, create: false)
        )
        let delegate = ToolchainManager.ResumableDownloadDelegate(
            partialFile: partialFile,
            expectedSize: UInt64(completeData.count),
            initialOffset: 4,
            label: "Downloading tools",
            onProgress: { _, _ in },
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

    func testArchiveEntryValidationRejectsAliasesDirectoriesAndDuplicates() throws {
        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []), urlSession: makeSession())

        XCTAssertThrowsError(try manager.test_validateArchiveEntries(["licenses/a//b.txt"]))
        XCTAssertThrowsError(try manager.test_validateArchiveEntries(["licenses/./a.txt"]))
        XCTAssertThrowsError(try manager.test_validateArchiveEntries(["licenses/a/../b.txt"]))
        XCTAssertThrowsError(try manager.test_validateArchiveEntries(["licenses/"]))
        XCTAssertThrowsError(try manager.test_validateArchiveEntries(["bin/colmap", "bin/colmap"]))
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

    func testArchiveInspectionRejectsSpecialFileEntries() throws {
        let runner = StreamingArchiveInspectionRunner(
            entries: ["bin/colmap"],
            metadataLines: [
                "prw-r--r--  3.0 unx   0 bx   0 stor 01-Jan-26 00:00 bin/control",
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
            XCTAssertTrue(message.contains("special file"))
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

    func testReceiptlessFutureSchemaCacheIsRejected() throws {
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
                schemaVersion: ToolchainManifest.currentSchemaVersion + 1,
                installedArtifacts: [
                    "macos-arm64-core": String(repeating: "a", count: 64),
                    "geometry-da3-base": String(repeating: "b", count: 64),
                ]
            ),
            root: root
        )
        let key = Curve25519.Signing.PrivateKey()

        XCTAssertThrowsError(
            try manager.test_validateSignedReceipt(
                root: root,
                publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString(),
                request: ToolchainCapabilityRequest(capabilities: [.da3Base])
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
        let basePaths = Self.baseFixtureContents.sorted()
        let smallPaths = Self.smallFixtureContents.sorted()
        func hashes(for paths: [String]) throws -> [String: String] {
            try Dictionary(uniqueKeysWithValues: paths.map { path in
                (path, try manager.test_sha256Hex(url: root.appendingPathComponent(path)))
            })
        }
        func closure(for paths: [String]) throws -> (
            sha256: String, sizeBytes: UInt64, fileHashes: [String: String]
        ) {
            try manager.test_expandedClosureEvidence(paths: paths, root: root)
        }
        let coreClosure = try closure(for: corePaths)
        let baseClosure = try closure(for: basePaths)
        let smallClosure = try closure(for: smallPaths)

        let unsigned = ToolchainManifest(
            schemaVersion: 2,
            toolchainAPI: 2,
            keyID: "",
            version: "2.0.0",
            publishedAt: Date(),
            appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
            components: [
                .init(name: "macos-arm64-core", capabilities: Array(ToolchainManager.coreCapabilities), url: "https://example.com/core.zip", sha256: String(repeating: "a", count: 64), sizeBytes: 1, expandedSizeBytes: coreClosure.sizeBytes, expandedClosureSHA256: coreClosure.sha256, contents: corePaths, criticalFileHashes: try hashes(for: corePaths), dependencies: [], requirement: .required),
                .init(name: "geometry-da3-base", capabilities: [ToolchainCapability.da3Runtime.rawValue, ToolchainCapability.da3Base.rawValue], url: "https://example.com/base.zip", sha256: String(repeating: "b", count: 64), sizeBytes: 1, expandedSizeBytes: baseClosure.sizeBytes, expandedClosureSHA256: baseClosure.sha256, contents: basePaths, criticalFileHashes: try hashes(for: basePaths), dependencies: ["macos-arm64-core"], requirement: .optional),
                .init(name: "geometry-da3-small", capabilities: [ToolchainCapability.da3Small.rawValue], url: "https://example.com/small.zip", sha256: String(repeating: "c", count: 64), sizeBytes: 1, expandedSizeBytes: smallClosure.sizeBytes, expandedClosureSHA256: smallClosure.sha256, contents: smallPaths, criticalFileHashes: try hashes(for: smallPaths), dependencies: ["geometry-da3-base"], requirement: .optional),
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

    func testSignedReceiptRejectsExecutableModeDrift() throws {
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
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: signed.fixture.colmap.path
        )

        XCTAssertThrowsError(try manager.test_validateSignedReceipt(
            root: root,
            publicKeyBase64: signed.publicKey,
            request: .init(capabilities: [.da3Base, .da3Small])
        ))
    }

    func testExpandedClosureRejectsSymlinkedIntermediateDirectory() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let actualBin = root.appendingPathComponent("actual-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: actualBin, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: actualBin.appendingPathComponent("tool"))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("bin"),
            withDestinationURL: actualBin
        )
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1"
        )

        XCTAssertThrowsError(try manager.test_expandedClosureEvidence(
            paths: ["bin/tool"],
            root: root
        ))
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
        let basePaths = Self.baseFixtureContents.sorted()
        let smallPaths = Self.smallFixtureContents.sorted()
        func hashes(for paths: [String]) throws -> [String: String] {
            try Dictionary(uniqueKeysWithValues: paths.map { path in
                (path, try manager.test_sha256Hex(url: backupRoot.appendingPathComponent(path)))
            })
        }
        func closure(for paths: [String]) throws -> (
            sha256: String, sizeBytes: UInt64, fileHashes: [String: String]
        ) {
            try manager.test_expandedClosureEvidence(paths: paths, root: backupRoot)
        }
        let coreClosure = try closure(for: corePaths)
        let baseClosure = try closure(for: basePaths)
        let smallClosure = try closure(for: smallPaths)
        let unsigned = ToolchainManifest(
            schemaVersion: 2,
            toolchainAPI: 2,
            keyID: "",
            version: version,
            publishedAt: Date(),
            appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
            components: [
                .init(name: "macos-arm64-core", capabilities: Array(ToolchainManager.coreCapabilities), url: "https://example.com/core.zip", sha256: String(repeating: "a", count: 64), sizeBytes: 1, expandedSizeBytes: coreClosure.sizeBytes, expandedClosureSHA256: coreClosure.sha256, contents: corePaths, criticalFileHashes: try hashes(for: corePaths), dependencies: [], requirement: .required),
                .init(name: "geometry-da3-base", capabilities: [ToolchainCapability.da3Runtime.rawValue, ToolchainCapability.da3Base.rawValue], url: "https://example.com/base.zip", sha256: String(repeating: "b", count: 64), sizeBytes: 1, expandedSizeBytes: baseClosure.sizeBytes, expandedClosureSHA256: baseClosure.sha256, contents: basePaths, criticalFileHashes: try hashes(for: basePaths), dependencies: ["macos-arm64-core"], requirement: .optional),
                .init(name: "geometry-da3-small", capabilities: [ToolchainCapability.da3Small.rawValue], url: "https://example.com/small.zip", sha256: String(repeating: "c", count: 64), sizeBytes: 1, expandedSizeBytes: smallClosure.sizeBytes, expandedClosureSHA256: smallClosure.sha256, contents: smallPaths, criticalFileHashes: try hashes(for: smallPaths), dependencies: ["geometry-da3-base"], requirement: .optional),
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

    func testInterruptedBackupReplacesReceiptlessCanonicalInstall() throws {
        let installationRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: installationRoot) }
        let version = "2.0.0"
        let canonicalRoot = installationRoot.appendingPathComponent(version, isDirectory: true)
        let backupRoot = installationRoot.appendingPathComponent(
            "\(version).backup-fixture",
            isDirectory: true
        )
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: installationRoot
        )
        let signed = try makeSignedCachedFixture(
            at: backupRoot,
            manager: manager,
            version: version
        )
        try FileManager.default.copyItem(at: backupRoot, to: canonicalRoot)
        try FileManager.default.removeItem(
            at: canonicalRoot.appendingPathComponent(ToolchainManager.installStateFilename)
        )

        try manager.test_recoverInterruptedInstalls(
            at: installationRoot,
            publicKeyBase64: signed.publicKey
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: backupRoot.path))
        XCTAssertNoThrow(
            try manager.test_validateSignedReceipt(
                root: canonicalRoot,
                publicKeyBase64: signed.publicKey,
                request: .init(capabilities: [.da3Base, .da3Small])
            )
        )
    }

    func testInterruptedRecoveryRejectsConflictingAuthenticatedManifestsAtSameSemanticVersion() throws {
        let installationRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: installationRoot) }
        let signingKey = Curve25519.Signing.PrivateKey()
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: installationRoot
        )
        let firstRoot = installationRoot.appendingPathComponent(
            "2.0.0.staging-first",
            isDirectory: true
        )
        let secondRoot = installationRoot.appendingPathComponent(
            "2.0.0.backup-second",
            isDirectory: true
        )
        let first = try makeSignedCachedFixture(
            at: firstRoot,
            manager: manager,
            version: "2.0.0+first",
            signingKey: signingKey
        )
        let second = try makeSignedCachedFixture(
            at: secondRoot,
            manager: manager,
            version: "2.0.0+second",
            signingKey: signingKey
        )
        XCTAssertNotEqual(first.manifest.signatureEd25519, second.manifest.signatureEd25519)

        XCTAssertThrowsError(
            try manager.test_recoverInterruptedInstalls(
                at: installationRoot,
                publicKeyBase64: first.publicKey
            )
        ) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected authenticated publication conflict, got \(error)")
            }
            XCTAssertTrue(message.contains("conflicts with its authenticated immutable manifest"))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: installationRoot.appendingPathComponent("2.0.0").path
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondRoot.path))
    }

    func testInterruptedRecoveryRejectsCandidateReplacedAfterValidationBeforePromotion() throws {
        let installationRoot = try TestFileBuilder.makeTempDir()
        let replacementRoot = try TestFileBuilder.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: installationRoot)
            try? FileManager.default.removeItem(at: replacementRoot)
        }
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: installationRoot
        )
        let stagingRoot = installationRoot.appendingPathComponent(
            "2.0.0.staging-original",
            isDirectory: true
        )
        let signed = try makeSignedCachedFixture(
            at: stagingRoot,
            manager: manager,
            version: "2.0.0"
        )
        let replacement = replacementRoot.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.copyItem(at: stagingRoot, to: replacement)
        let promotionAttempts = LockedCounter()

        XCTAssertThrowsError(
            try manager.test_recoverInterruptedInstalls(
                at: installationRoot,
                publicKeyBase64: signed.publicKey,
                beforeCandidatePromotion: { candidate in
                    XCTAssertEqual(candidate.standardizedFileURL, stagingRoot.standardizedFileURL)
                    _ = promotionAttempts.increment()
                    try FileManager.default.removeItem(at: candidate)
                    try FileManager.default.copyItem(at: replacement, to: candidate)
                }
            )
        ) { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected replaced recovery candidate failure, got \(error)")
            }
            XCTAssertTrue(message.contains("changed while recovery was in progress"))
        }
        XCTAssertEqual(promotionAttempts.current(), 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: installationRoot.appendingPathComponent("2.0.0").path
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingRoot.path))
    }

    func testPruningKeepsNewestFullyValidatedPreviousToolchain() throws {
        let installationRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: installationRoot) }
        let signingKey = Curve25519.Signing.PrivateKey()
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: installationRoot
        )
        let validRoot = installationRoot.appendingPathComponent("1.8.0", isDirectory: true)
        _ = try makeSignedCachedFixture(
            at: validRoot,
            manager: manager,
            version: "1.8.0",
            signingKey: signingKey
        )
        let corruptRoot = installationRoot.appendingPathComponent("1.9.0", isDirectory: true)
        let corrupt = try makeSignedCachedFixture(
            at: corruptRoot,
            manager: manager,
            version: "1.9.0",
            signingKey: signingKey
        )
        try FileManager.default.removeItem(at: corrupt.fixture.colmap)

        manager.pruneSchema2Toolchains(
            keeping: "2.0.0",
            publicKeyBase64: signingKey.publicKey.rawRepresentation.base64EncodedString()
        )

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: validRoot.path),
            "A signed receipt is not sufficient retention evidence when the newer closure is corrupt."
        )
    }

    func testPruningTreatsBuildMetadataVariantAsCurrentPublicationIdentity() throws {
        let installationRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: installationRoot) }
        let signingKey = Curve25519.Signing.PrivateKey()
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: installationRoot
        )
        let currentRoot = installationRoot.appendingPathComponent("2.0.0", isDirectory: true)
        _ = try makeSignedCachedFixture(
            at: currentRoot,
            manager: manager,
            version: "2.0.0+release",
            signingKey: signingKey
        )
        let previousRoot = installationRoot.appendingPathComponent("1.9.0", isDirectory: true)
        _ = try makeSignedCachedFixture(
            at: previousRoot,
            manager: manager,
            version: "1.9.0",
            signingKey: signingKey
        )
        let obsoleteRoot = installationRoot.appendingPathComponent("1.8.0", isDirectory: true)
        _ = try makeSignedCachedFixture(
            at: obsoleteRoot,
            manager: manager,
            version: "1.8.0",
            signingKey: signingKey
        )

        manager.pruneSchema2Toolchains(
            keeping: "2.0.0+release",
            publicKeyBase64: signingKey.publicKey.rawRepresentation.base64EncodedString()
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: currentRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: previousRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: obsoleteRoot.path))
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
        var failureDescription = ""
        do {
            _ = try await replacement.value
            XCTFail("Expected the incomplete replacement to fail validation")
        } catch {
            failureDescription = String(describing: error)
        }

        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: parent.path)
            .filter { $0.contains(".backup-") || $0.contains(".staging-") }
        XCTAssertTrue(
            leftovers.isEmpty,
            "Leftovers: \(leftovers); failure: \(failureDescription)"
        )
    }

    func testAtomicInstallDoesNotDeleteDirectorySubstitutedBeforeAttestation() async throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let versionedRoot = parent.appendingPathComponent("2.0.0", isDirectory: true)
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            installationRoot: parent
        )
        let substitutedRoots = LockedMessages()
        let install = Task.detached {
            try await manager.installToolchainAtomically(
                versionedRoot: versionedRoot,
                requiredCapabilities: [.core],
                onProgress: { _, _ in }
            ) { stagingRoot in
                try FileManager.default.removeItem(at: stagingRoot)
                try FileManager.default.createDirectory(
                    at: stagingRoot,
                    withIntermediateDirectories: false
                )
                try Data("do not delete".utf8).write(
                    to: stagingRoot.appendingPathComponent("sentinel")
                )
                substitutedRoots.append(stagingRoot.path)
                throw URLError(.cancelled)
            }
        }
        do {
            _ = try await install.value
            XCTFail("Expected the substituted install to fail")
        } catch {
            // Expected: the install closure deliberately stops before attestation.
        }

        let root = URL(fileURLWithPath: try XCTUnwrap(substitutedRoots.all().first))
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("sentinel")),
            Data("do not delete".utf8)
        )
    }

    func testAtomicInstallRejectsStagingDirectorySwapAndPreservesCanonicalInstall() async throws {
        let parent = try TestFileBuilder.makeTempDir()
        let replacementParent = try TestFileBuilder.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: parent)
            try? FileManager.default.removeItem(at: replacementParent)
        }
        let versionedRoot = parent.appendingPathComponent("2.0.0", isDirectory: true)
        let fixtureManager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: parent
        )
        let signed = try makeSignedCachedFixture(at: versionedRoot, manager: fixtureManager)
        let signedLicensePath = "licenses/Ceres/LICENSE"
        let canonicalLicense = versionedRoot.appendingPathComponent(signedLicensePath)
        let canonicalLicenseBefore = try Data(contentsOf: canonicalLicense)
        let replacement = replacementParent.appendingPathComponent("replacement", isDirectory: true)
        try FileManager.default.copyItem(at: versionedRoot, to: replacement)
        try Data("working but unattested replacement".utf8).write(
            to: replacement.appendingPathComponent(signedLicensePath)
        )
        let swaps = LockedCounter()
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(
                scripts: validationScripts(for: signed.fixture, installedAt: versionedRoot)
            ),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: parent
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await manager.test_installToolchainAtomically(
                versionedRoot: versionedRoot,
                requiredCapabilities: [.da3Base, .da3Small],
                authenticatedManifest: signed.manifest,
                seedFromExistingRoot: versionedRoot,
                beforeStagingPromotion: { stagingRoot in
                    _ = swaps.increment()
                    try FileManager.default.removeItem(at: stagingRoot)
                    try FileManager.default.copyItem(at: replacement, to: stagingRoot)
                },
                onProgress: { _, _ in },
                installInto: { _ in }
            )
        }, errorHandler: { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected staging identity failure, got \(error)")
            }
            XCTAssertTrue(message.contains("changed while preparing the install"))
        })
        XCTAssertEqual(swaps.current(), 1)
        XCTAssertEqual(try Data(contentsOf: canonicalLicense), canonicalLicenseBefore)
        XCTAssertNoThrow(
            try manager.test_validateSignedReceipt(
                root: versionedRoot,
                publicKeyBase64: signed.publicKey,
                request: .init(capabilities: [.da3Base, .da3Small])
            )
        )
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

    func testSandboxDeniedManifestRequestUsesAuthenticatedOfflineFallback() {
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession()
        )

        for code in [EPERM, EACCES] {
            XCTAssertTrue(
                manager.shouldAttemptOfflineFallback(
                    forManifestError: NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                )
            )
        }
        XCTAssertFalse(
            manager.shouldAttemptOfflineFallback(
                forManifestError: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))
            )
        )
    }

    func testDefaultToolchainSessionDoesNotPersistHTTPState() {
        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []))
        let configuration = manager.urlSession.configuration

        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testStreamingArtifactSessionInheritsNonpersistentHTTPConfiguration() {
        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []))
        let queue = OperationQueue()
        let session = manager.makeStreamingArtifactSession(
            delegate: EmptyURLSessionDelegate(),
            delegateQueue: queue
        )
        defer { session.invalidateAndCancel() }
        let configuration = session.configuration

        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
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

    func testArtifact404FallsBackToPreviousAuthenticatedToolchainWithoutRetrying() async throws {
        let installationRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: installationRoot) }
        let signingKey = Curve25519.Signing.PrivateKey()
        let previousRoot = installationRoot.appendingPathComponent("2.0.0", isDirectory: true)
        let fixtureManager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: installationRoot
        )
        let previous = try makeSignedCachedFixture(
            at: previousRoot,
            manager: fixtureManager,
            version: "2.0.0",
            signingKey: signingKey
        )

        let token = UUID().uuidString
        let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
        var nextManifest = previous.manifest
        nextManifest.version = "2.1.0"
        nextManifest.publishedAt = Date(timeIntervalSince1970: 1)
        nextManifest.signatureEd25519 = ""
        for index in nextManifest.components.indices {
            nextManifest.components[index].url = tokenizedURL(
                "https://example.com/\(nextManifest.components[index].name).zip",
                token: token
            ).absoluteString
        }
        let next = try signedV2Manifest(nextManifest, key: signingKey)
        let componentRequests = LockedCounter()
        MockURLProtocol.register(token: token) { request in
            if request.url == manifestURL {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    next.data
                )
            }
            _ = componentRequests.increment()
            return (
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { MockURLProtocol.unregister(token: token) }
        let messages = LockedMessages()
        let canonicalPreviousRoot = URL(
            fileURLWithPath: try canonicalFileSystemPath(previousRoot),
            isDirectory: true
        )
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(
                scripts: validationScripts(for: previous.fixture, installedAt: canonicalPreviousRoot)
            ),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: installationRoot
        )

        let toolchain = try await manager.ensureToolchain(
            manifestURL: manifestURL,
            publicKeyBase64: next.publicKey,
            request: .init(capabilities: [.core, .colmap, .msplat]),
            onProgress: { _, message in messages.append(message) }
        )

        XCTAssertEqual(
            try canonicalFileSystemPath(toolchain.root),
            try canonicalFileSystemPath(previousRoot)
        )
        XCTAssertEqual(componentRequests.current(), 1)
        XCTAssertTrue(messages.all().contains("Tools ready (offline cached)"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: installationRoot.appendingPathComponent("2.1.0", isDirectory: true).path
            )
        )
    }

    func testArtifact404FallsBackToAuthenticatedBundledCore() async throws {
        let temporaryRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let installationRoot = temporaryRoot.appendingPathComponent("install", isDirectory: true)
        let sourceRoot = temporaryRoot.appendingPathComponent("source", isDirectory: true)
        let versionedRoot = installationRoot.appendingPathComponent("2.0.0", isDirectory: true)
        let bootstrapManifestURL = temporaryRoot.appendingPathComponent("bootstrap-manifest.json")
        let bootstrapArchiveURL = temporaryRoot.appendingPathComponent("bootstrap-core.zip")
        let archiveData = Data("fixture bundled core archive".utf8)
        let signingKey = Curve25519.Signing.PrivateKey()
        let fixtureManager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: installationRoot
        )
        let bootstrap = try makeSignedCachedFixture(
            at: sourceRoot,
            manager: fixtureManager,
            coreArchiveData: archiveData,
            version: "2.0.0",
            signingKey: signingKey
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bootstrap.manifest).write(to: bootstrapManifestURL)
        try archiveData.write(to: bootstrapArchiveURL)

        let token = UUID().uuidString
        let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
        var remoteManifest = bootstrap.manifest
        remoteManifest.version = "2.1.0"
        remoteManifest.publishedAt = Date(timeIntervalSince1970: 1)
        remoteManifest.signatureEd25519 = ""
        for index in remoteManifest.components.indices {
            remoteManifest.components[index].url = tokenizedURL(
                "https://example.com/\(remoteManifest.components[index].name).zip",
                token: token
            ).absoluteString
        }
        let remote = try signedV2Manifest(remoteManifest, key: signingKey)
        let componentRequests = LockedCounter()
        MockURLProtocol.register(token: token) { request in
            if request.url == manifestURL {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    remote.data
                )
            }
            _ = componentRequests.increment()
            return (
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { MockURLProtocol.unregister(token: token) }

        let extraction = MockSubprocessRunner.Script(
            path: "/usr/bin/unzip",
            argsPrefix: ["-o", bootstrapArchiveURL.path, "-d"],
            result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
            onRun: { arguments in
                let destination = URL(fileURLWithPath: arguments[3], isDirectory: true)
                for relativePath in Self.coreFixtureContents {
                    let source = bootstrap.fixture.root.appendingPathComponent(relativePath)
                    let target = destination.appendingPathComponent(relativePath)
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.copyItem(at: source, to: target)
                }
            }
        )
        let canonicalVersionedRoot = URL(
            fileURLWithPath: try canonicalFileSystemPath(temporaryRoot),
            isDirectory: true
        )
            .appendingPathComponent("install", isDirectory: true)
            .appendingPathComponent("2.0.0", isDirectory: true)
        let runner = MockSubprocessRunner(
            scripts: bootstrapArchiveInspectionScripts(contents: Self.coreFixtureContents)
                + bootstrapArchiveInspectionScripts(contents: Self.coreFixtureContents)
                + [extraction]
                + validationScripts(for: bootstrap.fixture, installedAt: versionedRoot)
                + validationScripts(
                    for: bootstrap.fixture,
                    installedAt: canonicalVersionedRoot
                )
        )
        let messages = LockedMessages()
        let manager = ToolchainManager(
            runner: runner,
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: installationRoot,
            bundledBootstrap: .init(
                manifestURL: bootstrapManifestURL,
                coreArchiveURL: bootstrapArchiveURL
            )
        )

        let toolchain = try await manager.ensureToolchain(
            manifestURL: manifestURL,
            publicKeyBase64: remote.publicKey,
            request: .init(capabilities: [.core, .colmap, .msplat]),
            onProgress: { _, message in messages.append(message) }
        )

        XCTAssertEqual(
            try canonicalFileSystemPath(toolchain.root),
            try canonicalFileSystemPath(versionedRoot)
        )
        XCTAssertEqual(componentRequests.current(), 1)
        XCTAssertTrue(messages.all().contains("Tools ready (bundled)"))
    }

    func testAuthenticatedManifestCannotReplaceDifferentIdentityAtSameVersion() async throws {
        let installationRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: installationRoot) }
        let signingKey = Curve25519.Signing.PrivateKey()
        let versionedRoot = installationRoot.appendingPathComponent("2.0.0", isDirectory: true)
        let fixtureManager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: installationRoot
        )
        let installed = try makeSignedCachedFixture(
            at: versionedRoot,
            manager: fixtureManager,
            version: "2.0.0",
            signingKey: signingKey
        )

        let token = UUID().uuidString
        let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
        var conflictingManifest = installed.manifest
        conflictingManifest.publishedAt = installed.manifest.publishedAt.addingTimeInterval(1)
        conflictingManifest.signatureEd25519 = ""
        for index in conflictingManifest.components.indices {
            conflictingManifest.components[index].url = tokenizedURL(
                "https://example.com/\(conflictingManifest.components[index].name).zip",
                token: token
            ).absoluteString
        }
        let conflicting = try signedV2Manifest(conflictingManifest, key: signingKey)
        let componentRequests = LockedCounter()
        MockURLProtocol.register(token: token) { request in
            if request.url == manifestURL {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    conflicting.data
                )
            }
            _ = componentRequests.increment()
            return (
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { MockURLProtocol.unregister(token: token) }
        let canonicalRoot = URL(
            fileURLWithPath: try canonicalFileSystemPath(versionedRoot),
            isDirectory: true
        )
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(
                scripts: validationScripts(for: installed.fixture, installedAt: canonicalRoot)
            ),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: installationRoot
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await manager.ensureToolchain(
                manifestURL: manifestURL,
                publicKeyBase64: conflicting.publicKey,
                request: .init(capabilities: [.core, .colmap, .msplat]),
                onProgress: { _, _ in }
            )
        }, errorHandler: { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected immutable-version conflict, got \(error)")
            }
            XCTAssertTrue(message.contains("conflicts with its authenticated immutable manifest"))
        })
        XCTAssertEqual(componentRequests.current(), 0)
    }

    func testDamagedAuthenticatedReceiptRejectsBuildMetadataEquivocationBeforeComponentRequest() async throws {
        let installationRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: installationRoot) }
        let signingKey = Curve25519.Signing.PrivateKey()
        let installedRoot = installationRoot.appendingPathComponent("2.0.0", isDirectory: true)
        let fixtureManager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: installationRoot
        )
        let installed = try makeSignedCachedFixture(
            at: installedRoot,
            manager: fixtureManager,
            version: "2.0.0+installed",
            signingKey: signingKey
        )
        var historicalManifest = installed.manifest
        historicalManifest.appVersionRange = .init(
            minimum: "0.1.0",
            maximumExclusive: "0.2.0-beta.1"
        )
        historicalManifest.signatureEd25519 = ""
        let historical = try signedV2Manifest(historicalManifest, key: signingKey)
        try fixtureManager.saveInstallState(
            .init(
                schemaVersion: 2,
                installedArtifacts: Dictionary(
                    uniqueKeysWithValues: historical.manifest.components.map { ($0.name, $0.sha256) }
                ),
                installedCapabilities: Set(
                    historical.manifest.components.flatMap(\.capabilities)
                ).sorted(),
                signedManifest: historical.manifest
            ),
            root: installedRoot
        )
        try FileManager.default.removeItem(at: installed.fixture.colmap)

        let token = UUID().uuidString
        let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
        var conflictingManifest = historical.manifest
        conflictingManifest.version = "2.0.0+replacement"
        conflictingManifest.publishedAt = historical.manifest.publishedAt.addingTimeInterval(1)
        conflictingManifest.appVersionRange = .init(
            minimum: "0.2.0-beta.1",
            maximumExclusive: "0.3.0"
        )
        conflictingManifest.signatureEd25519 = ""
        for index in conflictingManifest.components.indices {
            conflictingManifest.components[index].url = tokenizedURL(
                "https://example.com/\(conflictingManifest.components[index].name).zip",
                token: token
            ).absoluteString
        }
        let conflicting = try signedV2Manifest(conflictingManifest, key: signingKey)
        let componentRequests = LockedCounter()
        MockURLProtocol.register(token: token) { request in
            if request.url == manifestURL {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    conflicting.data
                )
            }
            _ = componentRequests.increment()
            return (
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
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: installationRoot
        )

        XCTAssertEqual(
            try manager.test_versionedToolchainRoot(for: installed.manifest.version),
            try manager.test_versionedToolchainRoot(for: conflicting.manifest.version)
        )
        await XCTAssertThrowsErrorAsync({
            _ = try await manager.ensureToolchain(
                manifestURL: manifestURL,
                publicKeyBase64: conflicting.publicKey,
                request: .init(capabilities: [.core, .colmap, .msplat]),
                onProgress: { _, _ in }
            )
        }, errorHandler: { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected immutable semantic-version conflict, got \(error)")
            }
            XCTAssertTrue(message.contains("conflicts with its authenticated immutable manifest"))
        })
        XCTAssertEqual(componentRequests.current(), 0)
    }

    func testEnsureToolchainHoldsSemanticVersionLockAcrossRecoveryAndCacheResolution() async throws {
        let installationRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: installationRoot) }
        let versionedRoot = installationRoot.appendingPathComponent("2.0.0", isDirectory: true)
        let fixtureManager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: installationRoot
        )
        let signed = try makeSignedCachedFixture(at: versionedRoot, manager: fixtureManager)
        let token = UUID().uuidString
        let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
        let manifestEncoder = JSONEncoder()
        manifestEncoder.dateEncodingStrategy = .iso8601
        let manifestData = try manifestEncoder.encode(signed.manifest)
        let manifestRequests = LockedCounter()
        MockURLProtocol.register(token: token) { request in
            _ = manifestRequests.increment()
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                manifestData
            )
        }
        defer { MockURLProtocol.unregister(token: token) }

        let lockURL = installationRoot.appendingPathComponent(".2.0.0.install.lock")
        let lockHolder = Process()
        let lockHolderInput = Pipe()
        let lockHolderOutput = Pipe()
        lockHolder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        lockHolder.arguments = [
            "-c",
            """
            import fcntl, os, sys
            descriptor = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
            os.fchmod(descriptor, 0o600)
            fcntl.lockf(descriptor, fcntl.LOCK_EX)
            print("locked", flush=True)
            os.read(0, 1)
            """,
            lockURL.path,
        ]
        lockHolder.standardInput = lockHolderInput
        lockHolder.standardOutput = lockHolderOutput
        lockHolder.standardError = Pipe()
        try lockHolder.run()
        XCTAssertEqual(
            lockHolderOutput.fileHandleForReading.readData(ofLength: 7),
            Data("locked\n".utf8)
        )
        var lockIsHeld = true
        defer {
            if lockIsHeld {
                try? lockHolderInput.fileHandleForWriting.write(contentsOf: Data([1]))
                try? lockHolderInput.fileHandleForWriting.close()
            }
            if lockHolder.isRunning { lockHolder.waitUntilExit() }
        }

        let messages = LockedMessages()
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(
                scripts: validationScripts(for: signed.fixture, installedAt: versionedRoot)
            ),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: installationRoot
        )
        let resolution = Task.detached {
            try await manager.ensureToolchain(
                manifestURL: manifestURL,
                publicKeyBase64: signed.publicKey,
                request: .init(capabilities: [.core, .colmap, .msplat]),
                onProgress: { _, message in messages.append(message) }
            )
        }
        while manifestRequests.current() == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(messages.all().contains("Validating tools"))

        try lockHolderInput.fileHandleForWriting.write(contentsOf: Data([1]))
        try lockHolderInput.fileHandleForWriting.close()
        lockHolder.waitUntilExit()
        XCTAssertEqual(lockHolder.terminationStatus, 0)
        lockIsHeld = false
        let toolchain = try await resolution.value
        XCTAssertEqual(toolchain.root.standardizedFileURL, versionedRoot.standardizedFileURL)
        XCTAssertTrue(messages.all().contains("Validating tools"))
    }

    func testInstallLockSerializesConcurrentTransactionsWithinSameProcess() async throws {
        let installationRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: installationRoot) }
        let versionedRoot = installationRoot.appendingPathComponent("2.0.0", isDirectory: true)
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: installationRoot
        )
        let releaseFirst = ToolchainInstallLockGate()
        let firstEntries = LockedCounter()
        let secondEntries = LockedCounter()
        let first = Task.detached {
            try await manager.test_withInstallLock(for: versionedRoot) {
                _ = firstEntries.increment()
                await releaseFirst.wait()
            }
        }
        while firstEntries.current() == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let second = Task.detached {
            try await manager.test_withInstallLock(for: versionedRoot) {
                _ = secondEntries.increment()
            }
        }

        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(secondEntries.current(), 0)
        await releaseFirst.open()
        try await first.value
        try await second.value
        XCTAssertEqual(secondEntries.current(), 1)
    }

    func testCancelledInstallLockWaiterReturnsPromptlyWithoutEnteringTransaction() async throws {
        let installationRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: installationRoot) }
        let versionedRoot = installationRoot.appendingPathComponent("2.0.0", isDirectory: true)
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: installationRoot
        )
        let releaseHolder = ToolchainInstallLockGate()
        let holderEntries = LockedCounter()
        let waiterEntries = LockedCounter()
        let waiterOutcomes = LockedMessages()
        let holder = Task.detached {
            try await manager.test_withInstallLock(for: versionedRoot) {
                _ = holderEntries.increment()
                await releaseHolder.wait()
            }
        }
        while holderEntries.current() == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let waiterFinished = expectation(description: "cancelled lock waiter finished")
        let waiter = Task.detached {
            defer { waiterFinished.fulfill() }
            do {
                try await manager.test_withInstallLock(for: versionedRoot) {
                    _ = waiterEntries.increment()
                }
                waiterOutcomes.append("completed")
            } catch is CancellationError {
                waiterOutcomes.append("cancelled")
            } catch {
                waiterOutcomes.append("error: \(error)")
            }
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        waiter.cancel()

        await fulfillment(of: [waiterFinished], timeout: 0.25)
        XCTAssertEqual(waiterOutcomes.all(), ["cancelled"])
        XCTAssertEqual(waiterEntries.current(), 0)
        await releaseHolder.open()
        try await holder.value
        _ = await waiter.result
    }

    func testCancelledOfflineFallbackWaitingForRecoveryLockReturnsPromptly() async throws {
        let installationRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: installationRoot) }
        let interruptedRoot = installationRoot.appendingPathComponent(
            "2.0.0.staging-offline",
            isDirectory: true
        )
        let fixtureManager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: installationRoot
        )
        let signed = try makeSignedCachedFixture(at: interruptedRoot, manager: fixtureManager)
        try FileManager.default.removeItem(at: signed.fixture.colmap)

        let lockURL = installationRoot.appendingPathComponent(".2.0.0.install.lock")
        let lockHolder = Process()
        let lockHolderInput = Pipe()
        let lockHolderOutput = Pipe()
        lockHolder.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        lockHolder.arguments = [
            "-c",
            """
            import fcntl, os, sys
            descriptor = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
            os.fchmod(descriptor, 0o600)
            fcntl.lockf(descriptor, fcntl.LOCK_EX)
            print("locked", flush=True)
            os.read(0, 1)
            """,
            lockURL.path,
        ]
        lockHolder.standardInput = lockHolderInput
        lockHolder.standardOutput = lockHolderOutput
        lockHolder.standardError = Pipe()
        try lockHolder.run()
        XCTAssertEqual(
            lockHolderOutput.fileHandleForReading.readData(ofLength: 7),
            Data("locked\n".utf8)
        )
        var lockIsHeld = true
        defer {
            if lockIsHeld {
                try? lockHolderInput.fileHandleForWriting.write(contentsOf: Data([1]))
                try? lockHolderInput.fileHandleForWriting.close()
            }
            if lockHolder.isRunning { lockHolder.waitUntilExit() }
        }

        let token = UUID().uuidString
        let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
        let manifestRequests = LockedCounter()
        MockURLProtocol.register(token: token) { request in
            _ = manifestRequests.increment()
            return (
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
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: installationRoot
        )
        let outcome = LockedMessages()
        let finished = expectation(description: "cancelled offline recovery finished")
        let resolution = Task.detached {
            defer { finished.fulfill() }
            do {
                _ = try await manager.ensureToolchain(
                    manifestURL: manifestURL,
                    publicKeyBase64: signed.publicKey,
                    request: .init(capabilities: [.core, .colmap, .msplat]),
                    onProgress: { _, _ in }
                )
                outcome.append("completed")
            } catch is CancellationError {
                outcome.append("cancelled")
            } catch {
                outcome.append("error: \(error)")
            }
        }
        while manifestRequests.current() == 0 {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        resolution.cancel()

        await fulfillment(of: [finished], timeout: 0.25)
        XCTAssertEqual(outcome.all(), ["cancelled"])

        try lockHolderInput.fileHandleForWriting.write(contentsOf: Data([1]))
        try lockHolderInput.fileHandleForWriting.close()
        lockHolder.waitUntilExit()
        lockIsHeld = false
        _ = await resolution.result
    }

    func testEnsureToolchainUsesValidSignedCacheWithoutNetworkOrReceiptMutation() async throws {
        let temporaryRoot = try TestFileBuilder.makeTempDir()
        let installationRoot = temporaryRoot.path.hasPrefix("/var/")
            ? URL(fileURLWithPath: "/private\(temporaryRoot.path)", isDirectory: true)
            : temporaryRoot
        defer { try? FileManager.default.removeItem(at: installationRoot) }
        let versionedRoot = installationRoot.appendingPathComponent("2.0.0", isDirectory: true)
        let fixtureManager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            localToolchainRoot: nil,
            installationRoot: installationRoot
        )
        let signed = try makeSignedCachedFixture(at: versionedRoot, manager: fixtureManager)
        let receipt = versionedRoot.appendingPathComponent(".easysplat_toolchain_state.json")
        let receiptBefore = try Data(contentsOf: receipt)
        var statusBefore = stat()
        XCTAssertEqual(lstat(receipt.path, &statusBefore), 0)

        let requests = LockedCounter()
        let token = UUID().uuidString
        let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
        MockURLProtocol.register(token: token) { request in
            _ = requests.increment()
            return (
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { MockURLProtocol.unregister(token: token) }
        let messages = LockedMessages()
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: validationScripts(for: signed.fixture)),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            localToolchainRoot: nil,
            installationRoot: installationRoot,
            sourcePolicy: .cachedOnly
        )

        let toolchain = try await manager.ensureToolchain(
            manifestURL: manifestURL,
            publicKeyBase64: signed.publicKey,
            request: .init(capabilities: [.da3Base, .da3Small]),
            onProgress: { _, message in messages.append(message) }
        )

        var statusAfter = stat()
        XCTAssertEqual(lstat(receipt.path, &statusAfter), 0)
        XCTAssertEqual(toolchain.root.standardizedFileURL, versionedRoot.standardizedFileURL)
        XCTAssertEqual(requests.current(), 0)
        XCTAssertEqual(try Data(contentsOf: receipt), receiptBefore)
        XCTAssertEqual(statusAfter.st_dev, statusBefore.st_dev)
        XCTAssertEqual(statusAfter.st_ino, statusBefore.st_ino)
        XCTAssertEqual(statusAfter.st_mode, statusBefore.st_mode)
        XCTAssertEqual(statusAfter.st_nlink, statusBefore.st_nlink)
        XCTAssertTrue(messages.all().contains("Trying cached tools"))
        XCTAssertTrue(messages.all().contains("Tools ready (offline cached)"))
    }

    func testValidatedInstallationEvidenceUsesSignedComponentsAndExactClosure() throws {
        let installationRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: installationRoot) }
        let versionedRoot = installationRoot.appendingPathComponent("2.0.0", isDirectory: true)
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            localToolchainRoot: nil,
            installationRoot: installationRoot
        )
        let signed = try makeSignedCachedFixture(at: versionedRoot, manager: manager)
        var state = manager.loadInstallState(root: versionedRoot)
        state.installedCapabilities = ["forged.capability"]
        try manager.saveInstallState(state, root: versionedRoot)
        let request = ToolchainCapabilityRequest(capabilities: [.da3Base, .da3Small])

        let evidence = try manager.validatedInstallationEvidence(
            root: versionedRoot,
            publicKeyBase64: signed.publicKey,
            request: request,
            matching: signed.manifest
        )

        XCTAssertEqual(evidence.toolchainVersion, signed.manifest.version)
        XCTAssertEqual(evidence.keyID, signed.manifest.keyID)
        XCTAssertEqual(
            evidence.canonicalManifestSHA256,
            SHA256.hash(data: try signed.manifest.canonicalData())
                .map { String(format: "%02x", $0) }
                .joined()
        )
        let signature = try XCTUnwrap(Data(base64Encoded: signed.manifest.signatureEd25519))
        XCTAssertEqual(
            evidence.signatureSHA256,
            SHA256.hash(data: signature).map { String(format: "%02x", $0) }.joined()
        )
        XCTAssertEqual(
            evidence.installedArtifacts,
            Dictionary(uniqueKeysWithValues: signed.manifest.components.map {
                ($0.name, $0.sha256.lowercased())
            })
        )
        XCTAssertEqual(
            evidence.installedCapabilities,
            Set(signed.manifest.components.flatMap(\.capabilities)).sorted()
        )
        XCTAssertEqual(
            evidence.installedCriticalFileSHA256,
            signed.manifest.components.reduce(into: [:]) { result, component in
                result.merge(component.criticalFileHashes) { current, replacement in
                    XCTAssertEqual(current, replacement)
                    return current
                }
            }
        )
        XCTAssertEqual(
            evidence.nativeTrainerBuildDigest,
            try expectedNativeTrainerBuildDigest(root: versionedRoot)
        )
        XCTAssertFalse(evidence.installedCapabilities.contains("forged.capability"))
        XCTAssertEqual(evidence.closureSHA256.count, 64)
        XCTAssertEqual(
            evidence.signedComponents.map(\.name),
            signed.manifest.components.map(\.name)
        )
        XCTAssertEqual(
            evidence.signedComponents.first?.expandedClosureSHA256,
            signed.manifest.components.first?.expandedClosureSHA256
        )
        XCTAssertTrue(
            evidence.signedComponents.contains(where: {
                $0.declaredContents.contains("da3_mps/models/DA3-BASE/model.safetensors")
            })
        )
        XCTAssertTrue(
            evidence.provenanceRecords.contains(where: {
                $0.path == "msplat/build_info.json"
                    && $0.stringFields["source_version"] == "1.1.3"
            })
        )

        let unchanged = try manager.validatedInstallationEvidence(
            root: versionedRoot,
            publicKeyBase64: signed.publicKey,
            request: request,
            matching: signed.manifest
        )
        XCTAssertEqual(unchanged, evidence)

        let replacement = versionedRoot.appendingPathComponent("bin/.colmap-replacement")
        try Data(contentsOf: signed.fixture.colmap).write(to: replacement)
        let originalAttributes = try FileManager.default.attributesOfItem(
            atPath: signed.fixture.colmap.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: originalAttributes[.posixPermissions] ?? 0o755],
            ofItemAtPath: replacement.path
        )
        XCTAssertEqual(Darwin.rename(replacement.path, signed.fixture.colmap.path), 0)
        let replaced = try manager.validatedInstallationEvidence(
            root: versionedRoot,
            publicKeyBase64: signed.publicKey,
            request: request,
            matching: signed.manifest
        )
        XCTAssertEqual(replaced.closureSHA256, evidence.closureSHA256)
        XCTAssertNotEqual(
            replaced.installationIdentitySHA256,
            evidence.installationIdentitySHA256
        )

        try Data("mutated".utf8).write(to: signed.fixture.colmap)
        XCTAssertThrowsError(
            try manager.validatedInstallationEvidence(
                root: versionedRoot,
                publicKeyBase64: signed.publicKey,
                request: request,
                matching: signed.manifest
            )
        )
    }

    func testValidatedInstallationEvidenceAcceptsSignedSupplyChainAboveOneMiB() throws {
        let installationRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: installationRoot) }
        let versionedRoot = installationRoot.appendingPathComponent("2.0.0", isDirectory: true)
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            localToolchainRoot: nil,
            installationRoot: installationRoot
        )
        let supplyChain = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 1,
                "components": [],
                "files": [],
                "fixturePadding": String(repeating: "x", count: 1_100_000),
            ],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        XCTAssertGreaterThan(supplyChain.count, 1_024 * 1_024)
        XCTAssertLessThan(supplyChain.count, 16 * 1_024 * 1_024)
        let signed = try makeSignedCachedFixture(
            at: versionedRoot,
            manager: manager,
            additionalCoreFiles: ["supply-chain/components.json": supplyChain]
        )

        let evidence = try manager.validatedInstallationEvidence(
            root: versionedRoot,
            publicKeyBase64: signed.publicKey,
            request: .init(capabilities: [.da3Base, .da3Small]),
            matching: signed.manifest
        )

        XCTAssertTrue(evidence.provenanceRecords.contains(where: {
            $0.path == "supply-chain/components.json"
        }))
    }

    func testValidatedInstallationEvidenceRejectsDifferentExpectedManifest() throws {
        let installationRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: installationRoot) }
        let versionedRoot = installationRoot.appendingPathComponent("2.0.0", isDirectory: true)
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            localToolchainRoot: nil,
            installationRoot: installationRoot
        )
        let signed = try makeSignedCachedFixture(at: versionedRoot, manager: manager)
        var different = signed.manifest
        different.signatureEd25519 = Data(repeating: 0, count: 64).base64EncodedString()

        XCTAssertThrowsError(
            try manager.validatedInstallationEvidence(
                root: versionedRoot,
                publicKeyBase64: signed.publicKey,
                request: .init(capabilities: [.da3Base, .da3Small]),
                matching: different
            )
        )
    }

    func testNativeTrainerEvidenceRejectsPostClosureMutationAgainstSignedHashes() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1"
        )
        let signed = try makeSignedCachedFixture(at: root, manager: manager)
        let signedHashes = signed.manifest.components.reduce(into: [String: String]()) {
            $0.merge($1.criticalFileHashes) { current, replacement in
                XCTAssertEqual(current, replacement)
                return current
            }
        }

        XCTAssertNoThrow(try manager.test_nativeTrainerBuildDigest(
            root: root,
            signedFileHashes: signedHashes
        ))
        try Data("post-closure mutation".utf8).write(
            to: root.appendingPathComponent("bin/easysplat-train"),
            options: .atomic
        )

        XCTAssertThrowsError(try manager.test_nativeTrainerBuildDigest(
            root: root,
            signedFileHashes: signedHashes
        ))
    }

    func testValidatedInstallationEvidenceRejectsSignedTreeOutsideManagersVersionedRoot() throws {
        let installationRoot = try TestFileBuilder.makeTempDir()
        let outsideContainer = try TestFileBuilder.makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: installationRoot)
            try? FileManager.default.removeItem(at: outsideContainer)
        }
        let versionedRoot = installationRoot.appendingPathComponent("2.0.0", isDirectory: true)
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            localToolchainRoot: nil,
            installationRoot: installationRoot
        )
        let signed = try makeSignedCachedFixture(at: versionedRoot, manager: manager)
        let outsideRoot = outsideContainer.appendingPathComponent("2.0.0", isDirectory: true)
        try FileManager.default.copyItem(at: versionedRoot, to: outsideRoot)

        XCTAssertThrowsError(
            try manager.validatedInstallationEvidence(
                root: outsideRoot,
                publicKeyBase64: signed.publicKey,
                request: .init(capabilities: [.da3Base, .da3Small]),
                matching: signed.manifest
            )
        ) { error in
            guard let toolchainError = error as? ToolchainManager.ToolchainError,
                  case .invalidManifest = toolchainError else {
                return XCTFail("Expected invalidManifest, got \(error)")
            }
        }
    }

    func testCachedOnlyRejectsUnsignedLocalOverrideBeforeCacheOrNetworkAccess() async throws {
        let temporaryRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let installationRoot = temporaryRoot.appendingPathComponent("cache", isDirectory: true)
        let versionedRoot = installationRoot.appendingPathComponent("2.0.0", isDirectory: true)
        let localRoot = temporaryRoot.appendingPathComponent("unsigned-local", isDirectory: true)
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        let fixtureManager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            localToolchainRoot: nil,
            installationRoot: installationRoot
        )
        let signed = try makeSignedCachedFixture(at: versionedRoot, manager: fixtureManager)

        let requests = LockedCounter()
        let token = UUID().uuidString
        let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
        MockURLProtocol.register(token: token) { request in
            _ = requests.increment()
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { MockURLProtocol.unregister(token: token) }
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: validationScripts(for: signed.fixture)),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            localToolchainRoot: localRoot,
            installationRoot: installationRoot,
            sourcePolicy: .cachedOnly
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await manager.ensureToolchain(
                manifestURL: manifestURL,
                publicKeyBase64: signed.publicKey,
                request: .init(capabilities: [.da3Base, .da3Small]),
                onProgress: { _, _ in }
            )
        }, errorHandler: { error in
            guard case ToolchainManager.ToolchainError.invalidManifest = error else {
                return XCTFail("Expected invalidManifest, got \(error)")
            }
        })
        XCTAssertEqual(requests.current(), 0)
    }

    func testCachedOnlyDoesNotRepairExecutablePermissions() async throws {
        let installationRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: installationRoot) }
        let versionedRoot = installationRoot.appendingPathComponent("2.0.0", isDirectory: true)
        let fixtureManager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            localToolchainRoot: nil,
            installationRoot: installationRoot
        )
        let signed = try makeSignedCachedFixture(at: versionedRoot, manager: fixtureManager)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: signed.fixture.colmap.path
        )
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: validationScripts(for: signed.fixture)),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            localToolchainRoot: nil,
            installationRoot: installationRoot,
            sourcePolicy: .cachedOnly
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await manager.ensureToolchain(
                manifestURL: URL(string: "https://127.0.0.1:1/cached-only.json")!,
                publicKeyBase64: signed.publicKey,
                request: .init(capabilities: [.da3Base, .da3Small]),
                onProgress: { _, _ in }
            )
        }, errorHandler: { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected an incomplete signed core without a permission repair, got \(error)")
            }
            XCTAssertTrue(message.contains("Cached toolchain component is incomplete: macos-arm64-core"))
        })
        let attributes = try FileManager.default.attributesOfItem(atPath: signed.fixture.colmap.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)
    }

    func testCachedOnlyDoesNotRecoverInterruptedInstall() async throws {
        let installationRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: installationRoot) }
        let stagingRoot = installationRoot.appendingPathComponent("2.0.0.staging-test", isDirectory: true)
        let fixtureManager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            localToolchainRoot: nil,
            installationRoot: installationRoot
        )
        let signed = try makeSignedCachedFixture(at: stagingRoot, manager: fixtureManager)
        let receipt = stagingRoot.appendingPathComponent(".easysplat_toolchain_state.json")
        let receiptBefore = try Data(contentsOf: receipt)
        var statusBefore = stat()
        XCTAssertEqual(lstat(receipt.path, &statusBefore), 0)
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: validationScripts(for: signed.fixture)),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            localToolchainRoot: nil,
            installationRoot: installationRoot,
            sourcePolicy: .cachedOnly
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await manager.ensureToolchain(
                manifestURL: URL(string: "https://127.0.0.1:1/cached-only.json")!,
                publicKeyBase64: signed.publicKey,
                request: .init(capabilities: [.da3Base, .da3Small]),
                onProgress: { _, _ in }
            )
        }, errorHandler: { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected an unavailable signed cache, got \(error)")
            }
            XCTAssertTrue(message.contains("No verified cached toolchain"))
        })
        var statusAfter = stat()
        XCTAssertEqual(lstat(receipt.path, &statusAfter), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingRoot.path))
        XCTAssertEqual(try Data(contentsOf: receipt), receiptBefore)
        XCTAssertEqual(statusAfter.st_dev, statusBefore.st_dev)
        XCTAssertEqual(statusAfter.st_ino, statusBefore.st_ino)
        XCTAssertEqual(statusAfter.st_ctimespec.tv_sec, statusBefore.st_ctimespec.tv_sec)
        XCTAssertEqual(statusAfter.st_ctimespec.tv_nsec, statusBefore.st_ctimespec.tv_nsec)
    }

    func testBundledBootstrapOnlyInstallsSignedCoreWithoutNetworkAccess() async throws {
        let temporaryRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let installationRoot = temporaryRoot.appendingPathComponent("install", isDirectory: true)
        let sourceRoot = temporaryRoot.appendingPathComponent("source", isDirectory: true)
        let versionedRoot = installationRoot.appendingPathComponent("2.0.0", isDirectory: true)
        let archiveData = Data("fixture bundled core archive".utf8)
        let bootstrapManifestURL = temporaryRoot.appendingPathComponent("bootstrap-manifest.json")
        let bootstrapArchiveURL = temporaryRoot.appendingPathComponent("bootstrap-core.zip")
        let fixtureManager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            localToolchainRoot: nil,
            installationRoot: installationRoot
        )
        let fixture = try makeSignedCachedFixture(
            at: sourceRoot,
            manager: fixtureManager,
            coreArchiveData: archiveData
        )

        let requests = LockedCounter()
        let token = UUID().uuidString
        var unsignedManifest = fixture.manifest
        unsignedManifest.signatureEd25519 = ""
        for index in unsignedManifest.components.indices {
            let name = unsignedManifest.components[index].name
            unsignedManifest.components[index].url = tokenizedURL(
                "https://example.com/\(name).zip",
                token: token
            ).absoluteString
        }
        let signed = try signedV2Manifest(unsignedManifest)
        try signed.data.write(to: bootstrapManifestURL)
        try archiveData.write(to: bootstrapArchiveURL)
        MockURLProtocol.register(token: token) { request in
            _ = requests.increment()
            return (
                HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { MockURLProtocol.unregister(token: token) }

        let success = SubprocessResult(exitCode: 0, terminationReason: .exit, stdout: "", stderr: "")
        let extraction = MockSubprocessRunner.Script(
            path: "/usr/bin/unzip",
            argsPrefix: ["-o", bootstrapArchiveURL.path, "-d"],
            result: success,
            onRun: { arguments in
                guard arguments.count == 4 else {
                    throw NSError(
                        domain: "BundledBootstrapFixture",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Unexpected unzip arguments: \(arguments)"]
                    )
                }
                let destination = URL(fileURLWithPath: arguments[3], isDirectory: true)
                for relativePath in Self.coreFixtureContents {
                    let source = fixture.fixture.root.appendingPathComponent(relativePath)
                    let target = destination.appendingPathComponent(relativePath)
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.copyItem(at: source, to: target)
                }
            }
        )
        let inspectionScripts = bootstrapArchiveInspectionScripts(contents: Self.coreFixtureContents)
        let runner = MockSubprocessRunner(
            scripts: inspectionScripts
                + bootstrapArchiveInspectionScripts(contents: Self.coreFixtureContents)
                + [extraction]
                + validationScripts(for: fixture.fixture, installedAt: versionedRoot)
        )
        let messages = LockedMessages()
        let manager = ToolchainManager(
            runner: runner,
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            localToolchainRoot: nil,
            installationRoot: installationRoot,
            bundledBootstrap: .init(
                manifestURL: bootstrapManifestURL,
                coreArchiveURL: bootstrapArchiveURL
            ),
            sourcePolicy: .bundledBootstrapOnly
        )
        let request = ToolchainCapabilityRequest(capabilities: [.core, .colmap, .msplat])

        let toolchain = try await manager.ensureToolchain(
            manifestURL: tokenizedURL("https://example.com/manifest.json", token: token),
            publicKeyBase64: signed.publicKey,
            request: request,
            onProgress: { _, message in messages.append(message) }
        )

        let core = try XCTUnwrap(signed.manifest.components.first { $0.name == "macos-arm64-core" })
        let state = manager.loadInstallState(root: versionedRoot)
        let receipt = try manager.validateSignedReceipt(
            root: versionedRoot,
            publicKeyBase64: signed.publicKey,
            request: request
        )
        XCTAssertEqual(
            toolchain.root.resolvingSymlinksInPath(),
            versionedRoot.resolvingSymlinksInPath()
        )
        XCTAssertEqual(state.installedArtifacts, [core.name: core.sha256])
        XCTAssertEqual(Set(state.installedCapabilities), ToolchainManager.coreCapabilities)
        XCTAssertEqual(receipt.signatureEd25519, signed.manifest.signatureEd25519)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: versionedRoot.appendingPathComponent("da3_mps").path
            )
        )
        XCTAssertEqual(requests.current(), 0)
        XCTAssertTrue(messages.all().contains("Checking bundled tools"))
        XCTAssertTrue(messages.all().contains("Tools ready (bundled)"))
    }

    func testBundledBootstrapOnlyRejectsConflictingAuthenticatedPublicationBeforeExtraction() async throws {
        try await assertConflictingBundledBootstrapIsRejected(.bundledOnly)
    }

    func testOfflineFallbackRejectsConflictingAuthenticatedBootstrapBeforeExtraction() async throws {
        try await assertConflictingBundledBootstrapIsRejected(.offlineFallback)
    }

    func testBundledBootstrapOnlyRejectsUnsatisfiedRequestWithoutNetworkAccess() async throws {
        let temporaryRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let installationRoot = temporaryRoot.appendingPathComponent("install", isDirectory: true)
        let fixtureRoot = temporaryRoot.appendingPathComponent("fixture", isDirectory: true)
        let archiveData = Data("fixture bundled core archive".utf8)
        let bootstrapManifestURL = temporaryRoot.appendingPathComponent("bootstrap-manifest.json")
        let bootstrapArchiveURL = temporaryRoot.appendingPathComponent("bootstrap-core.zip")
        let fixtureManager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            localToolchainRoot: nil,
            installationRoot: installationRoot
        )
        let signed = try makeSignedCachedFixture(
            at: fixtureRoot,
            manager: fixtureManager,
            coreArchiveData: archiveData
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(signed.manifest).write(to: bootstrapManifestURL)
        try archiveData.write(to: bootstrapArchiveURL)

        let requests = LockedCounter()
        let token = UUID().uuidString
        let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
        MockURLProtocol.register(token: token) { request in
            _ = requests.increment()
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { MockURLProtocol.unregister(token: token) }
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(
                scripts: bootstrapArchiveInspectionScripts(contents: Self.coreFixtureContents)
            ),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            localToolchainRoot: nil,
            installationRoot: installationRoot,
            bundledBootstrap: .init(
                manifestURL: bootstrapManifestURL,
                coreArchiveURL: bootstrapArchiveURL
            ),
            sourcePolicy: .bundledBootstrapOnly
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await manager.ensureToolchain(
                manifestURL: manifestURL,
                publicKeyBase64: signed.publicKey,
                request: .init(capabilities: [.da3Base]),
                onProgress: { _, _ in }
            )
        }, errorHandler: { error in
            guard case ToolchainManager.ToolchainError.artifactNotFound = error else {
                return XCTFail("Expected an unsatisfied bundled-only request, got \(error)")
            }
        })
        XCTAssertEqual(requests.current(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installationRoot.path))
    }

    func testDA3RequestWithCorruptCacheAndValidCoreBootstrapReportsCacheIntegrityFailure() async throws {
        let installationRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: installationRoot) }
        let versionedRoot = installationRoot.appendingPathComponent("2.0.0", isDirectory: true)
        let archiveData = Data("fixture bundled core archive".utf8)
        let bootstrapManifestURL = installationRoot.appendingPathComponent("bootstrap-manifest.json")
        let bootstrapArchiveURL = installationRoot.appendingPathComponent("bootstrap-core.zip")
        let token = UUID().uuidString
        let remoteManifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
        let bootstrapManager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            localToolchainRoot: nil,
            installationRoot: installationRoot
        )
        let signed = try makeSignedCachedFixture(
            at: versionedRoot,
            manager: bootstrapManager,
            coreArchiveData: archiveData
        )
        let manifestEncoder = JSONEncoder()
        manifestEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        manifestEncoder.dateEncodingStrategy = .iso8601
        try manifestEncoder.encode(signed.manifest).write(to: bootstrapManifestURL)
        try archiveData.write(to: bootstrapArchiveURL)
        try Data("undeclared bytecode".utf8).write(
            to: versionedRoot.appendingPathComponent("da3_mps/python/runtime.pyc")
        )
        MockURLProtocol.register(token: token) { request in
            (
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { MockURLProtocol.unregister(token: token) }

        let inspectionScripts = bootstrapArchiveInspectionScripts(contents: Self.coreFixtureContents)
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: inspectionScripts),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            localToolchainRoot: nil,
            installationRoot: installationRoot,
            bundledBootstrap: .init(
                manifestURL: bootstrapManifestURL,
                coreArchiveURL: bootstrapArchiveURL
            )
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await manager.ensureToolchain(
                manifestURL: remoteManifestURL,
                publicKeyBase64: signed.publicKey,
                request: .init(capabilities: [.da3Base, .da3Small]),
                onProgress: { _, _ in }
            )
        }, errorHandler: { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected cached invalidToolchain, got \(error)")
            }
            XCTAssertTrue(message.contains("cached tools could not be verified"))
            XCTAssertTrue(message.contains("undeclared file"))
            XCTAssertTrue(message.contains("da3_mps/python/runtime.pyc"))
        })
    }

    func testCacheRejectsSignedReceiptCopiedUnderAnotherVersionDirectory() throws {
        let installationRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: installationRoot) }
        let misleadingRoot = installationRoot.appendingPathComponent("99.0.0", isDirectory: true)
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            localToolchainRoot: nil,
            installationRoot: installationRoot
        )
        let signed = try makeSignedCachedFixture(at: misleadingRoot, manager: manager)

        XCTAssertThrowsError(try manager.loadBestCachedToolchain(
            publicKeyBase64: signed.publicKey,
            request: .init(capabilities: [.da3Base, .da3Small]),
            minimumVersion: "1.0.0"
        ))
    }

    func testCacheFloorAllowsEqualAndNewerSignedReceiptVersions() throws {
        for floor in ["2.0.0", "1.9.9"] {
            let temporaryRoot = try TestFileBuilder.makeTempDir()
            let installationRoot = temporaryRoot.path.hasPrefix("/var/")
                ? URL(fileURLWithPath: "/private\(temporaryRoot.path)", isDirectory: true)
                : temporaryRoot
            defer { try? FileManager.default.removeItem(at: installationRoot) }
            let versionedRoot = installationRoot.appendingPathComponent("2.0.0", isDirectory: true)
            let bootstrapManager = ToolchainManager(
                runner: MockSubprocessRunner(scripts: []),
                urlSession: makeSession(),
                appVersion: "0.2.0-beta.1",
                localToolchainRoot: nil,
                installationRoot: installationRoot
            )
            let signed = try makeSignedCachedFixture(at: versionedRoot, manager: bootstrapManager)
            let manager = ToolchainManager(
                runner: MockSubprocessRunner(scripts: validationScripts(for: signed.fixture)),
                urlSession: makeSession(),
                appVersion: "0.2.0-beta.1",
                localToolchainRoot: nil,
                installationRoot: installationRoot
            )

            let result = try manager.loadBestCachedToolchain(
                publicKeyBase64: signed.publicKey,
                request: .init(capabilities: [.da3Base, .da3Small]),
                minimumVersion: floor
            )

            XCTAssertEqual(result?.root.standardizedFileURL, versionedRoot.standardizedFileURL)
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

    func testDownloadManifestAcceptsExactlyEightMiB() async throws {
        let maximumBytes = 8 * 1_024 * 1_024
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
        let maximumBytes = 8 * 1_024 * 1_024
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
            XCTAssertEqual(maximumBytes, 8 * 1_024 * 1_024)
        })
        XCTAssertEqual(requests.current(), 1)
    }

    func testDownloadManifestRejectsStreamingOverflowWithoutContentLength() async throws {
        let maximumBytes = 8 * 1_024 * 1_024
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
            XCTAssertEqual(maximumBytes, 8 * 1_024 * 1_024)
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
            for firstCapability in [ToolchainCapability.da3Base] {
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

            let temporaryInstallationRoot = try TestFileBuilder.makeTempDir()
            guard let canonicalPath = realpath(temporaryInstallationRoot.path, nil) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            defer { free(canonicalPath) }
            let installationRoot = URL(
                fileURLWithPath: String(cString: canonicalPath),
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: installationRoot) }
            let bootstrap = ToolchainManager(
                runner: MockSubprocessRunner(scripts: []),
                localToolchainRoot: nil,
                installationRoot: installationRoot
            )
            let versionedRoot = bootstrap.toolchainRoot().appendingPathComponent(version, isDirectory: true)
            try? FileManager.default.removeItem(at: versionedRoot)
            let seedFixture = try ToolchainFixtureBuilder.createToolchain(at: versionedRoot)
            let coreClosure = try bootstrap.test_expandedClosureEvidence(
                paths: Self.coreFixtureContents,
                root: versionedRoot
            )
            let baseContents = Self.baseFixtureContents
            let smallContents = Self.smallFixtureContents
            let baseClosure = try bootstrap.test_expandedClosureEvidence(
                paths: baseContents,
                root: versionedRoot
            )
            let smallClosure = try bootstrap.test_expandedClosureEvidence(
                paths: smallContents,
                root: versionedRoot
            )
            let basePayloads = try Dictionary(uniqueKeysWithValues: baseContents.map { path in
                (path, try Data(contentsOf: versionedRoot.appendingPathComponent(path)))
            })
            let smallPayloads = try Dictionary(uniqueKeysWithValues: smallContents.map { path in
                (path, try Data(contentsOf: versionedRoot.appendingPathComponent(path)))
            })
            let baseModes = try Dictionary(uniqueKeysWithValues: baseContents.map { path in
                let attributes = try FileManager.default.attributesOfItem(
                    atPath: versionedRoot.appendingPathComponent(path).path
                )
                return (path, (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644)
            })
            let smallModes = try Dictionary(uniqueKeysWithValues: smallContents.map { path in
                let attributes = try FileManager.default.attributesOfItem(
                    atPath: versionedRoot.appendingPathComponent(path).path
                )
                return (path, (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644)
            })
            try FileManager.default.removeItem(at: versionedRoot)
            defer { try? FileManager.default.removeItem(at: versionedRoot) }

            func componentHash(_ data: Data) -> String {
                SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
            let manifest = ToolchainManifest(
                schemaVersion: 2,
                toolchainAPI: 2,
                keyID: "",
                version: version,
                publishedAt: Date(),
                appVersionRange: .init(minimum: "1.0.0", maximumExclusive: "3.0.0"),
                components: [
                    .init(name: "macos-arm64-core", capabilities: ["runtime.core", "geometry.colmap", "training.msplat"], url: coreURL.absoluteString, sha256: componentHash(coreData), sizeBytes: UInt64(coreData.count), expandedSizeBytes: coreClosure.sizeBytes, expandedClosureSHA256: coreClosure.sha256, contents: Self.coreFixtureContents, criticalFileHashes: coreClosure.fileHashes, dependencies: [], requirement: .required),
                    .init(name: "geometry-da3-base", capabilities: ["geometry.da3.runtime", "geometry.da3.base"], url: baseURL.absoluteString, sha256: componentHash(baseData), sizeBytes: UInt64(baseData.count), expandedSizeBytes: baseClosure.sizeBytes, expandedClosureSHA256: baseClosure.sha256, contents: baseContents, criticalFileHashes: baseClosure.fileHashes, dependencies: ["macos-arm64-core"], requirement: .optional),
                    .init(name: "geometry-da3-small", capabilities: ["geometry.da3.small"], url: smallURL.absoluteString, sha256: componentHash(smallData), sizeBytes: UInt64(smallData.count), expandedSizeBytes: smallClosure.sizeBytes, expandedClosureSHA256: smallClosure.sha256, contents: smallContents, criticalFileHashes: smallClosure.fileHashes, dependencies: ["geometry-da3-base"], requirement: .optional),
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
                    try? FileManager.default.removeItem(at: destination.appendingPathComponent("da3_mps"))
                }
            )
            let baseUnzip = MockSubprocessRunner.Script(
                path: "/usr/bin/unzip",
                argsPrefix: ["-o"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { @Sendable args in
                    guard let index = args.firstIndex(of: "-d") else { return }
                    let destination = URL(fileURLWithPath: args[index + 1], isDirectory: true)
                    for (path, payload) in basePayloads {
                        let file = destination.appendingPathComponent(path)
                        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                        FileManager.default.createFile(atPath: file.path, contents: payload)
                        try? FileManager.default.setAttributes(
                            [.posixPermissions: baseModes[path] ?? 0o644],
                            ofItemAtPath: file.path
                        )
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
                    for (path, payload) in smallPayloads {
                        let file = destination.appendingPathComponent(path)
                        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                        FileManager.default.createFile(atPath: file.path, contents: payload)
                        try? FileManager.default.setAttributes(
                            [.posixPermissions: smallModes[path] ?? 0o644],
                            ofItemAtPath: file.path
                        )
                    }
                }
            )
            let firstModelUnzip = firstCapability == .da3Base ? baseUnzip : smallUnzip
            let secondModelUnzip = firstCapability == .da3Base ? smallUnzip : baseUnzip
            let temporaryAliasRoot = URL(
                fileURLWithPath: versionedRoot.path.replacingOccurrences(
                    of: "/private/var/",
                    with: "/var/"
                ),
                isDirectory: true
            )
            let validation = (0..<4).flatMap { _ in
                validationScripts(for: seedFixture, installedAt: versionedRoot)
                    + validationScripts(for: seedFixture, installedAt: temporaryAliasRoot)
            }
            let runner = MockSubprocessRunner(
                scripts: [coreUnzip, firstModelUnzip, secondModelUnzip]
                    + validation
            )
            let manager = ToolchainManager(
                runner: runner,
                urlSession: makeSession(),
                appVersion: "2.0.0",
                localToolchainRoot: nil,
                installationRoot: installationRoot
            )

            let toolchain = try await manager.ensureToolchain(
                manifestURL: manifestURL,
                publicKeyBase64: signed.publicKey,
                request: .init(capabilities: [firstCapability]),
                onProgress: { _, _ in }
            )

            XCTAssertEqual(
                try canonicalFileSystemPath(toolchain.root),
                try canonicalFileSystemPath(versionedRoot)
            )
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
                Set(ToolchainManager.coreCapabilities).union([
                    ToolchainCapability.da3Runtime.rawValue,
                    firstCapability.rawValue,
                ])
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: changedHashPartial.path))
        try Data(repeating: 0x04, count: 9).write(to: changedVersionPartial)

        let cleanedOversizedPartial = try manager.preparePartialDownload(
            artifact: changedHashArtifact,
            url: secondURL,
            installationRoot: nextVersionRoot
        )
        XCTAssertEqual(cleanedOversizedPartial.path, changedVersionPartial.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cleanedOversizedPartial.path))
    }

    func testPreparingAnotherVersionDoesNotUnlinkLiveCrossProcessPartial() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession()
        )
        let artifactURL = URL(string: "https://example.com/core.zip")!
        let artifact = testComponent(
            name: "macos-arm64-core",
            url: artifactURL.absoluteString,
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 8,
            contents: ["bin/colmap"]
        )
        let firstRoot = parent.appendingPathComponent("2.0.0.staging-first", isDirectory: true)
        let nextRoot = parent.appendingPathComponent("2.0.1.staging-first", isDirectory: true)
        let firstPartial = try manager.preparePartialDownload(
            artifact: artifact,
            url: artifactURL,
            installationRoot: firstRoot
        )
        try Data([0x01]).write(to: firstPartial)

        let writer = Process()
        let writerInput = Pipe()
        let writerOutput = Pipe()
        writer.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        writer.arguments = [
            "-c",
            """
            import os, sys
            descriptor = os.open(sys.argv[1], os.O_WRONLY | os.O_APPEND)
            print("open", flush=True)
            os.read(0, 1)
            os.write(descriptor, b"\\x02")
            os.fsync(descriptor)
            os.close(descriptor)
            """,
            firstPartial.path,
        ]
        writer.standardInput = writerInput
        writer.standardOutput = writerOutput
        writer.standardError = Pipe()
        try writer.run()
        XCTAssertEqual(
            writerOutput.fileHandleForReading.readData(ofLength: 5),
            Data("open\n".utf8)
        )
        var writerReleased = false
        defer {
            if !writerReleased {
                try? writerInput.fileHandleForWriting.write(contentsOf: Data([1]))
                try? writerInput.fileHandleForWriting.close()
            }
            if writer.isRunning { writer.waitUntilExit() }
        }

        _ = try manager.preparePartialDownload(
            artifact: artifact,
            url: artifactURL,
            installationRoot: nextRoot
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstPartial.path))

        try writerInput.fileHandleForWriting.write(contentsOf: Data([1]))
        try writerInput.fileHandleForWriting.close()
        writer.waitUntilExit()
        writerReleased = true
        XCTAssertEqual(writer.terminationStatus, 0)
        if FileManager.default.fileExists(atPath: firstPartial.path) {
            XCTAssertEqual(try Data(contentsOf: firstPartial), Data([0x01, 0x02]))
        }
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

    func testBundledDiskRequirementExcludesLocalArchiveBytesAndAllowsExactBoundary() throws {
        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []), urlSession: makeSession())
        let component = ToolchainManifest.Component(
            name: "macos-arm64-core",
            capabilities: Array(ToolchainManager.coreCapabilities),
            url: "https://example.com/core.zip",
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 900_000_000,
            expandedSizeBytes: 1_200_000_000,
            contents: ["bin/colmap"],
            criticalFileHashes: ["bin/colmap": String(repeating: "b", count: 64)],
            dependencies: [],
            requirement: .required
        )
        let headroom: UInt64 = 64 * 1_024 * 1_024

        let required = try manager.requiredBundledDiskBytes(for: component)

        XCTAssertEqual(required, headroom + component.expandedSizeBytes)
        XCTAssertNoThrow(try manager.validateAvailableDiskSpace(required: required, available: required))
        XCTAssertThrowsError(try manager.validateAvailableDiskSpace(required: required, available: required - 1))
    }

    func testBundledReplacementDoesNotChargeExistingCanonicalTreeAsBackup() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x01, count: 4_096).write(to: root.appendingPathComponent("existing.bin"))
        let component = testComponent(
            name: "macos-arm64-core",
            url: "https://example.com/core.zip",
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 8_192,
            contents: ["bin/colmap"]
        )
        var expanded = component
        expanded.expandedSizeBytes = 16_384
        let manager = ToolchainManager(runner: MockSubprocessRunner(scripts: []), urlSession: makeSession())
        let headroom: UInt64 = 64 * 1_024 * 1_024

        XCTAssertEqual(
            try manager.requiredBundledDiskBytes(for: expanded),
            headroom + expanded.expandedSizeBytes
        )
        XCTAssertEqual(
            try manager.requiredBundledDiskBytes(for: expanded, seedFromExistingRoot: root),
            headroom + expanded.expandedSizeBytes + 4_096
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

    func testPartialResumeRejectsSymlinkAndHardLinkBeforeRequestOrVictimWrite() async throws {
        enum AliasKind: CaseIterable { case symbolic, hard }
        for kind in AliasKind.allCases {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let token = UUID().uuidString
            let artifactURL = tokenizedURL("https://example.com/models.zip", token: token)
            let prefix = Data("safe".utf8)
            let zipData = prefix + Data("-bytes".utf8)
            let zipHash = SHA256.hash(data: zipData)
                .map { String(format: "%02x", $0) }
                .joined()
            let artifact = testComponent(
                name: "geometry-da3-base",
                url: artifactURL.absoluteString,
                sha256: zipHash,
                sizeBytes: UInt64(zipData.count),
                contents: ["model.safetensors"]
            )
            let manager = ToolchainManager(
                runner: MockSubprocessRunner(scripts: []),
                urlSession: makeSession()
            )
            let partialURL = try manager.preparePartialDownload(
                artifact: artifact,
                url: artifactURL,
                installationRoot: root
            )
            let victim = root.appendingPathComponent("victim-\(kind)")
            try prefix.write(to: victim)
            switch kind {
            case .symbolic:
                try FileManager.default.createSymbolicLink(at: partialURL, withDestinationURL: victim)
            case .hard:
                XCTAssertEqual(Darwin.link(victim.path, partialURL.path), 0)
            }
            let requests = LockedCounter()
            MockURLProtocol.register(token: token) { request in
                _ = requests.increment()
                let suffix = Data(zipData.dropFirst(prefix.count))
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 206,
                        httpVersion: nil,
                        headerFields: [
                            "Content-Range": "bytes \(prefix.count)-\(zipData.count - 1)/\(zipData.count)"
                        ]
                    )!,
                    suffix
                )
            }

            await XCTAssertThrowsErrorAsync({
                try await manager.downloadVerifiedArtifact(
                    artifact,
                    from: artifactURL,
                    to: root.appendingPathComponent("verified.zip"),
                    installationRoot: root,
                    label: "Downloading tools",
                    onProgress: { _, _ in }
                )
            })
            MockURLProtocol.unregister(token: token)
            XCTAssertEqual(requests.current(), 0, "Unsafe \(kind) alias reached the network")
            XCTAssertEqual(try Data(contentsOf: victim), prefix, "Unsafe \(kind) alias mutated its victim")
        }
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

    func testRangeNotSatisfiableRetriesOnceImmediatelyWithoutRange() async throws {
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
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession()
        )
        let partialURL = try manager.preparePartialDownload(
            artifact: artifact,
            url: artifactURL,
            installationRoot: root
        )
        try Data(zipData.prefix(4)).write(to: partialURL)
        let ranges = LockedMessages()
        let requests = LockedCounter()
        MockURLProtocol.register(token: token) { request in
            ranges.append(request.value(forHTTPHeaderField: "Range") ?? "none")
            switch requests.increment() {
            case 1:
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 416,
                        httpVersion: nil,
                        headerFields: ["Content-Range": "bytes */\(zipData.count)"]
                    )!,
                    Data()
                )
            case 2:
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    zipData
                )
            default:
                throw URLError(.badServerResponse)
            }
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
        XCTAssertEqual(requests.current(), 2)
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

    func testEnsureArtifactPreservesNonretryableHTTPStatusAndURL() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let token = UUID().uuidString
        let artifactURL = tokenizedURL("https://example.com/missing.zip", token: token)
        let requests = LockedCounter()
        let artifact = testComponent(
            name: "geometry-da3-base",
            url: artifactURL.absoluteString,
            sha256: String(repeating: "a", count: 64),
            sizeBytes: 1,
            contents: ["da3_mps/models/DA3-BASE/model.safetensors"]
        )
        MockURLProtocol.register(token: token) { request in
            _ = requests.increment()
            return (
                HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { MockURLProtocol.unregister(token: token) }
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession()
        )

        await XCTAssertThrowsErrorAsync({
            try await manager.test_ensureArtifact(artifact, root: root) { _, _ in }
        }, errorHandler: { error in
            guard case let ToolchainManager.ToolchainError.artifactHTTPFailure(statusCode, resourceURL) = error else {
                return XCTFail("Expected artifactHTTPFailure, got \(error)")
            }
            XCTAssertEqual(statusCode, 404)
            XCTAssertEqual(resourceURL, artifactURL)
        })
        XCTAssertEqual(requests.current(), 1)
    }

    func testEnsureArtifactRetriesTransientHTTPFailure() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let token = UUID().uuidString
        let artifactURL = tokenizedURL("https://example.com/component.zip", token: token)
        let zipData = Data("zip-bytes".utf8)
        let zipHash = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        let requests = LockedCounter()
        let relativePath = "da3_mps/models/DA3-BASE/model.safetensors"
        let artifact = testComponent(
            name: "geometry-da3-base",
            url: artifactURL.absoluteString,
            sha256: zipHash,
            sizeBytes: UInt64(zipData.count),
            contents: [relativePath]
        )
        MockURLProtocol.register(token: token) { request in
            let attempt = requests.increment()
            let statusCode = attempt == 1 ? 503 : 200
            return (
                HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!,
                statusCode == 200 ? zipData : Data()
            )
        }
        defer { MockURLProtocol.unregister(token: token) }
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: "/usr/bin/unzip",
                argsPrefix: ["-o"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { @Sendable _ in
                    let expectedFile = root.appendingPathComponent(relativePath)
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

        XCTAssertEqual(requests.current(), 2)
    }

    func testComponentTransferFallbackRejectsIntegrityAndPolicyFailures() {
        let manager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession()
        )
        let rejected: [ToolchainManager.ToolchainError] = [
            .invalidManifest,
            .signatureFailed,
            .hashMismatch,
            .unzipFailed,
            .invalidToolchain("fixture"),
            .invalidArtifactURL("fixture"),
        ]

        for error in rejected {
            XCTAssertFalse(
                manager.shouldAttemptOfflineFallback(forComponentTransferError: error),
                "Unsafe fallback accepted \(error)"
            )
        }
    }

    private func testComponent(
        name: String,
        url: String,
        sha256: String,
        sizeBytes: UInt64,
        contents: [String]
    ) -> ToolchainManifest.Component {
        let fileHash = SHA256.hash(data: Data([0x00]))
            .map { String(format: "%02x", $0) }
            .joined()
        var closureHasher = SHA256()
        closureHasher.update(data: Data("EasySplat expanded component closure v1\n".utf8))
        for path in contents.sorted() {
            closureHasher.update(data: Data(path.utf8))
            closureHasher.update(data: Data([0]))
            closureHasher.update(data: Data(String(0o644).utf8))
            closureHasher.update(data: Data([0]))
            closureHasher.update(data: Data("1".utf8))
            closureHasher.update(data: Data([0]))
            closureHasher.update(data: Data(fileHash.utf8))
            closureHasher.update(data: Data([10]))
        }
        let closureHash = closureHasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        return ToolchainManifest.Component(
            name: name,
            capabilities: ["test.component"],
            url: url,
            sha256: sha256,
            sizeBytes: sizeBytes,
            expandedSizeBytes: UInt64(contents.count),
            expandedClosureSHA256: closureHash,
            contents: contents,
            criticalFileHashes: Dictionary(
                uniqueKeysWithValues: contents.map { ($0, fileHash) }
            ),
            dependencies: [],
            requirement: .required
        )
    }

    private func makeSignedCachedFixture(
        at root: URL,
        manager: ToolchainManager,
        additionalCoreFiles: [String: Data] = [:],
        coreArchiveData: Data? = nil,
        version: String = "2.0.0",
        signingKey: Curve25519.Signing.PrivateKey = .init()
    ) throws -> (fixture: ToolchainFixture, publicKey: String, manifest: ToolchainManifest) {
        let fixture = try ToolchainFixtureBuilder.createToolchain(at: root)
        for (relativePath, data) in additionalCoreFiles {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }

        let coreContents = Set(Self.coreFixtureContents).union(additionalCoreFiles.keys).sorted()
        let baseContents = Self.baseFixtureContents.sorted()
        let smallContents = Self.smallFixtureContents.sorted()
        func expandedClosure(for paths: [String]) throws -> (
            digest: String,
            size: UInt64,
            hashes: [String: String]
        ) {
            let evidence = try manager.test_expandedClosureEvidence(paths: paths, root: root)
            return (evidence.sha256, evidence.sizeBytes, evidence.fileHashes)
        }

        let coreClosure = try expandedClosure(for: coreContents)
        let baseClosure = try expandedClosure(for: baseContents)
        let smallClosure = try expandedClosure(for: smallContents)
        let coreArchiveSHA = coreArchiveData.map {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        } ?? String(repeating: "a", count: 64)
        let coreArchiveSize = coreArchiveData.map { UInt64($0.count) } ?? 1
        let unsigned = ToolchainManifest(
            schemaVersion: 2,
            toolchainAPI: 2,
            keyID: "",
            version: version,
            publishedAt: Date(timeIntervalSince1970: 0),
            appVersionRange: .init(minimum: "0.2.0-beta.1", maximumExclusive: "0.3.0"),
            components: [
                .init(name: "macos-arm64-core", capabilities: Array(ToolchainManager.coreCapabilities), url: "https://example.com/core.zip", sha256: coreArchiveSHA, sizeBytes: coreArchiveSize, expandedSizeBytes: coreClosure.size, expandedClosureSHA256: coreClosure.digest, contents: coreContents, criticalFileHashes: coreClosure.hashes, dependencies: [], requirement: .required),
                .init(name: "geometry-da3-base", capabilities: [ToolchainCapability.da3Runtime.rawValue, ToolchainCapability.da3Base.rawValue], url: "https://example.com/base.zip", sha256: String(repeating: "b", count: 64), sizeBytes: 1, expandedSizeBytes: baseClosure.size, expandedClosureSHA256: baseClosure.digest, contents: baseContents, criticalFileHashes: baseClosure.hashes, dependencies: ["macos-arm64-core"], requirement: .optional),
                .init(name: "geometry-da3-small", capabilities: [ToolchainCapability.da3Small.rawValue], url: "https://example.com/small.zip", sha256: String(repeating: "c", count: 64), sizeBytes: 1, expandedSizeBytes: smallClosure.size, expandedClosureSHA256: smallClosure.digest, contents: smallContents, criticalFileHashes: smallClosure.hashes, dependencies: ["geometry-da3-base"], requirement: .optional),
            ],
            signatureEd25519: ""
        )
        let signed = try signedV2Manifest(unsigned, key: signingKey)
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
        return (fixture, signed.publicKey, signed.manifest)
    }

    private func installStateData(exactly byteCount: Int) throws -> Data {
        let empty = ToolchainManager.ToolchainInstallState(
            installedArtifacts: ["macos-arm64-core": ""]
        )
        let emptyData = try JSONEncoder().encode(empty)
        guard byteCount >= emptyData.count else {
            throw NSError(domain: "ToolchainManagerDownloadTests", code: 1)
        }
        let state = ToolchainManager.ToolchainInstallState(
            installedArtifacts: [
                "macos-arm64-core": String(repeating: "a", count: byteCount - emptyData.count)
            ]
        )
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(data.count, byteCount)
        return data
    }

    private func bootstrapArchiveInspectionScripts(
        contents: [String]
    ) -> [MockSubprocessRunner.Script] {
        let success = SubprocessResult(exitCode: 0, terminationReason: .exit, stdout: "", stderr: "")
        return [
            .init(
                path: "/usr/bin/zipinfo",
                argsPrefix: ["-l"],
                result: success,
                stdoutLines: contents.map {
                    "-rw-r--r--  3.0 unx 1 bx 1 stor 01-Jan-26 00:00 \($0)"
                }
            ),
            .init(
                path: "/usr/bin/unzip",
                argsPrefix: ["-Z1"],
                result: success,
                stdoutLines: contents
            ),
        ]
    }

    private func validationScripts(
        for fixture: ToolchainFixture,
        installedAt installedRoot: URL? = nil
    ) -> [MockSubprocessRunner.Script] {
        let root = installedRoot ?? fixture.root
        let colmap = root.appendingPathComponent("bin/colmap")
        let da3Python = root.appendingPathComponent("da3_mps/python/bin/python3")
        let da3SfmTool = root.appendingPathComponent("da3_mps/bin/easysplat_da3_sfm")
        let msplat = root.appendingPathComponent("bin/easysplat-train")
        return [
            .init(
                path: "/usr/bin/file",
                argsPrefix: ["-b", colmap.path],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "Mach-O 64-bit executable arm64", stderr: ""),
                onRun: nil
            ),
            .init(
                path: colmap.path,
                argsPrefix: ["help"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: NativeColmapHelpFixture.root,
                    stderr: ""
                ),
                onRun: nil
            ),
            .init(
                path: colmap.path,
                argsPrefix: ["matches_importer", "-h"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: NativeColmapHelpFixture.matchesImporter,
                    stderr: ""
                ),
                onRun: nil
            ),
            .init(
                path: colmap.path,
                argsPrefix: ["mapper", "-h"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: NativeColmapHelpFixture.mapper,
                    stderr: ""
                ),
                onRun: nil
            ),
            .init(
                path: colmap.path,
                argsPrefix: ["local_vocab_retriever", "-h"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: NativeColmapHelpFixture.vocabulary,
                    stderr: ""
                ),
                onRun: nil
            ),
            .init(
                path: "/usr/bin/file",
                argsPrefix: ["-b", da3Python.path],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "Mach-O 64-bit executable arm64", stderr: ""),
                onRun: nil
            ),
            .init(
                path: da3SfmTool.path,
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
                    stdout: "{\"event\":\"self_check\",\"isolation_mode_version\":1,\"scene_bounds_status\":\"ok\",\"schema_version\":2,\"sequence\":1,\"status\":\"ok\",\"version\":\"1.1.3 (git 106499b)\"}\n",
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

    private func signedV2Manifest(
        _ unsigned: ToolchainManifest,
        key: Curve25519.Signing.PrivateKey = .init()
    ) throws -> (manifest: ToolchainManifest, publicKey: String, data: Data) {
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
        var manifest = unsigned
        manifest.keyID = ToolchainManifest.keyID(publicKeyBase64: publicKey)!
        manifest.signatureEd25519 = try key.signature(for: manifest.canonicalData()).base64EncodedString()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return (manifest, publicKey, try encoder.encode(manifest))
    }

    private func expectedNativeTrainerBuildDigest(root: URL) throws -> String {
        var hasher = SHA256()
        hasher.update(data: Data("EasySplat file digest v1".utf8))
        for name in ["easysplat-train", "default.metallib"] {
            let bytes = try Data(contentsOf: root.appendingPathComponent("bin/\(name)"))
            var nameLength = UInt64(name.utf8.count).bigEndian
            withUnsafeBytes(of: &nameLength) { hasher.update(bufferPointer: $0) }
            hasher.update(data: Data(name.utf8))
            var byteCount = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &byteCount) { hasher.update(bufferPointer: $0) }
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private enum BundledConflictPath {
        case bundledOnly
        case offlineFallback
    }

    private func assertConflictingBundledBootstrapIsRejected(
        _ path: BundledConflictPath
    ) async throws {
        let temporaryRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let installationRoot = temporaryRoot.appendingPathComponent("install", isDirectory: true)
        let canonicalRoot = installationRoot.appendingPathComponent("2.0.0", isDirectory: true)
        let bundleSourceRoot = temporaryRoot.appendingPathComponent("bundle-source", isDirectory: true)
        let bootstrapManifestURL = temporaryRoot.appendingPathComponent("bootstrap-manifest.json")
        let bootstrapArchiveURL = temporaryRoot.appendingPathComponent("bootstrap-core.zip")
        let archiveData = Data("conflicting bundled core archive".utf8)
        let signingKey = Curve25519.Signing.PrivateKey()
        let fixtureManager = ToolchainManager(
            runner: MockSubprocessRunner(scripts: []),
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: installationRoot
        )
        let installed = try makeSignedCachedFixture(
            at: canonicalRoot,
            manager: fixtureManager,
            version: "2.0.0+installed",
            signingKey: signingKey
        )
        let bundled = try makeSignedCachedFixture(
            at: bundleSourceRoot,
            manager: fixtureManager,
            coreArchiveData: archiveData,
            version: "2.0.0+bundle",
            signingKey: signingKey
        )
        XCTAssertNotEqual(
            installed.manifest.signatureEd25519,
            bundled.manifest.signatureEd25519
        )
        try FileManager.default.removeItem(at: installed.fixture.colmap)
        let receipt = canonicalRoot.appendingPathComponent(ToolchainManager.installStateFilename)
        let receiptBefore = try Data(contentsOf: receipt)
        var receiptStatusBefore = stat()
        XCTAssertEqual(lstat(receipt.path, &receiptStatusBefore), 0)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bundled.manifest).write(to: bootstrapManifestURL)
        try archiveData.write(to: bootstrapArchiveURL)

        let extractions = LockedCounter()
        let extraction = MockSubprocessRunner.Script(
            path: "/usr/bin/unzip",
            argsPrefix: ["-o", bootstrapArchiveURL.path, "-d"],
            result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
            onRun: { arguments in
                _ = extractions.increment()
                let destination = URL(fileURLWithPath: arguments[3], isDirectory: true)
                for relativePath in Self.coreFixtureContents {
                    let source = bundled.fixture.root.appendingPathComponent(relativePath)
                    let target = destination.appendingPathComponent(relativePath)
                    try FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.copyItem(at: source, to: target)
                }
            }
        )
        let runner = MockSubprocessRunner(
            scripts: bootstrapArchiveInspectionScripts(contents: Self.coreFixtureContents)
                + bootstrapArchiveInspectionScripts(contents: Self.coreFixtureContents)
                + [extraction]
                + validationScripts(for: bundled.fixture, installedAt: canonicalRoot)
        )
        let token = UUID().uuidString
        let manifestURL = tokenizedURL("https://example.com/manifest.json", token: token)
        let manifestRequests = LockedCounter()
        MockURLProtocol.register(token: token) { request in
            _ = manifestRequests.increment()
            return (
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
        let manager = ToolchainManager(
            runner: runner,
            urlSession: makeSession(),
            appVersion: "0.2.0-beta.1",
            installationRoot: installationRoot,
            bundledBootstrap: .init(
                manifestURL: bootstrapManifestURL,
                coreArchiveURL: bootstrapArchiveURL
            ),
            sourcePolicy: path == .bundledOnly ? .bundledBootstrapOnly : .automatic
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await manager.ensureToolchain(
                manifestURL: manifestURL,
                publicKeyBase64: bundled.publicKey,
                request: .init(capabilities: [.core, .colmap, .msplat]),
                onProgress: { _, _ in }
            )
        }, errorHandler: { error in
            guard case ToolchainManager.ToolchainError.invalidToolchain(let message) = error else {
                return XCTFail("Expected immutable bundled publication conflict, got \(error)")
            }
            XCTAssertTrue(message.contains("conflicts with its authenticated immutable manifest"))
        })
        XCTAssertEqual(extractions.current(), 0)
        XCTAssertEqual(manifestRequests.current(), path == .bundledOnly ? 0 : 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.fixture.colmap.path))
        XCTAssertEqual(try Data(contentsOf: receipt), receiptBefore)
        var receiptStatusAfter = stat()
        XCTAssertEqual(lstat(receipt.path, &receiptStatusAfter), 0)
        XCTAssertEqual(receiptStatusAfter.st_dev, receiptStatusBefore.st_dev)
        XCTAssertEqual(receiptStatusAfter.st_ino, receiptStatusBefore.st_ino)
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

    private func canonicalFileSystemPath(_ url: URL) throws -> String {
        guard let canonicalPath = realpath(url.path, nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(canonicalPath) }
        return String(cString: canonicalPath)
    }
}

private actor ToolchainInstallLockGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
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
        removingEnvironmentKeys: Set<String>,
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
        removingEnvironmentKeys: Set<String>,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) async throws -> SubprocessResult {
        try run(
            launchPath,
            arguments,
            currentDirectory: currentDirectory,
            environment: environment,
            removingEnvironmentKeys: removingEnvironmentKeys,
            onStdout: onStdout,
            onStderr: onStderr
        )
    }
}
