import Foundation
import XCTest
@testable import ManifestToolCore

final class ReleaseSigningTests: XCTestCase {
    private let repository = "dud8/EasySplat"
    private let sourceCommit = String(repeating: "a", count: 40)
    private let version = "2.0.0"
    private let appRange = ManifestDocument.AppVersionRange(
        minimum: "0.2.0-beta.1",
        maximumExclusive: "0.3.0"
    )

    func testPrepareReleaseCreatesCanonicalUnsignedRequestBoundToArchives() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let request = try ManifestBuilder.prepareRelease(
            repository: repository,
            sourceCommit: sourceCommit,
            version: version,
            publishedAt: Date(timeIntervalSince1970: 0),
            appVersionRange: appRange,
            publicKeyBase64: fixture.publicKeyBase64,
            components: fixture.inputs
        )
        let data = try ManifestBuilder.canonicalData(for: request)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertEqual(try decoder.decode(ReleaseSigningRequest.self, from: data), request)
        XCTAssertEqual(request.schemaVersion, 1)
        XCTAssertEqual(request.sourceRepository, repository)
        XCTAssertEqual(request.sourceCommit, sourceCommit)
        XCTAssertEqual(request.manifest.signatureEd25519, "")
        XCTAssertEqual(request.manifest.components.map(\.name), [
            "macos-arm64-core",
            "geometry-da3-base",
            "geometry-da3-small",
        ])
        XCTAssertEqual(
            request.manifestSHA256,
            ManifestBuilder.sha256Hex(data: try ManifestBuilder.canonicalData(for: request.manifest))
        )
    }

    func testPrepareReleaseRejectsAComponentOutsideTheReleaseClosure() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        var inputs = fixture.inputs
        inputs[0] = ManifestArtifactInput(
            name: inputs[0].name,
            artifactURL: "https://attacker.example/core.zip",
            zipURL: inputs[0].zipURL,
            capabilities: inputs[0].capabilities,
            dependencies: inputs[0].dependencies,
            requirement: inputs[0].requirement,
            criticalFilePaths: inputs[0].criticalFilePaths
        )

        XCTAssertThrowsError(try ManifestBuilder.prepareRelease(
            repository: repository,
            sourceCommit: sourceCommit,
            version: version,
            publishedAt: Date(timeIntervalSince1970: 0),
            appVersionRange: appRange,
            publicKeyBase64: fixture.publicKeyBase64,
            components: inputs
        ))
    }

    func testReleaseCommandArgumentsRejectUnknownAndDuplicateOptions() throws {
        let unknown = ArgParser(["--request", "request.json", "--archive", "payload.zip"])
        XCTAssertThrowsError(try unknown.requireOnly(["--request"]))

        let duplicate = ArgParser(["--request", "first.json", "--request", "second.json"])
        XCTAssertThrowsError(try duplicate.requireOnly(["--request"]))

        let exact = ArgParser(["--request-out", "request.json", "--version", version])
        XCTAssertNoThrow(try exact.requireOnly(["--request-out", "--version"]))
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let core = try makeZip(
            named: "core",
            files: Dictionary(uniqueKeysWithValues: ManifestToolDefaults.criticalCoreFiles.map {
                ($0, Data($0.utf8))
            }),
            in: root
        )
        let base = try makeZip(
            named: "base",
            files: Dictionary(uniqueKeysWithValues: ManifestToolDefaults.da3BaseContents.map {
                ($0, Data($0.utf8))
            }),
            in: root
        )
        let small = try makeZip(
            named: "small",
            files: Dictionary(uniqueKeysWithValues: ManifestToolDefaults.da3SmallContents.map {
                ($0, Data($0.utf8))
            }),
            in: root
        )
        let publicKeyBase64 = ManifestBuilder.generateKeypair().publicKeyBase64
        let urls = ManifestBuilder.releaseComponentURLs(repository: repository, version: version)
        return Fixture(
            root: root,
            publicKeyBase64: publicKeyBase64,
            inputs: [
                .init(name: "macos-arm64-core", artifactURL: urls["macos-arm64-core"]!, zipURL: core, capabilities: ManifestToolDefaults.coreCapabilities, dependencies: [], requirement: .required, criticalFilePaths: ManifestToolDefaults.criticalCoreFiles),
                .init(name: "geometry-da3-base", artifactURL: urls["geometry-da3-base"]!, zipURL: base, capabilities: ["geometry.da3.base"], dependencies: ["macos-arm64-core"], requirement: .required, criticalFilePaths: ManifestToolDefaults.da3BaseContents),
                .init(name: "geometry-da3-small", artifactURL: urls["geometry-da3-small"]!, zipURL: small, capabilities: ["geometry.da3.small"], dependencies: ["macos-arm64-core"], requirement: .optional, criticalFilePaths: ManifestToolDefaults.da3SmallContents),
            ]
        )
    }

    private func makeZip(named name: String, files: [String: Data], in root: URL) throws -> URL {
        let source = root.appendingPathComponent("\(name)-source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for (path, data) in files {
            let destination = source.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination)
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
            throw NSError(domain: "ReleaseSigningTests", code: 1)
        }
        return zip
    }
}

private struct Fixture {
    let root: URL
    let publicKeyBase64: String
    let inputs: [ManifestArtifactInput]

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
