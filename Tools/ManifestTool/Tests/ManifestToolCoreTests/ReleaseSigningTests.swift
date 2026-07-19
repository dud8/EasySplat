import CryptoKit
import Foundation
import XCTest
@testable import ManifestToolCore

final class ReleaseSigningTests: XCTestCase {
    private let repository = "dud8/EasySplat"
    private let sourceCommit: String = {
        let process = Process()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "HEAD"]
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try! process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }()
    private let version = "2.0.0"
    private let appRange = ManifestDocument.AppVersionRange(
        minimum: "0.2.0-beta.1",
        maximumExclusive: "0.3.0"
    )

    func testPrepareReleaseCreatesCanonicalUnsignedRequestBoundToArchives() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let request = try prepareRelease(fixture, inputs: fixture.inputs)
        let data = try ManifestBuilder.canonicalData(for: request)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertEqual(try decoder.decode(ReleaseSigningRequest.self, from: data), request)
        XCTAssertEqual(request.schemaVersion, 2)
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

    func testBuilderAttestedRequestDigestDistinguishesCoupledPayloadMutations() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let original = try prepareRelease(fixture, inputs: fixture.inputs)
        let originalDigest = ManifestBuilder.sha256Hex(
            data: try ManifestBuilder.canonicalData(for: original)
        )

        var nativeMutation = fixture.files
        let replacementBinary = Data("coupled native replacement".utf8)
        nativeMutation.core["bin/colmap"] = replacementBinary
        var nativeReceipt = try jsonObject(nativeMutation.core["provenance/colmap.json"]!)
        nativeReceipt["executable_sha256"] = ProductionToolchainFileFixture.sha256(replacementBinary)
        nativeMutation.core["provenance/colmap.json"] = try ProductionToolchainFileFixture.json(
            nativeReceipt
        )
        try nativeMutation.refreshSupplyChain()
        let nativeRequest = try prepareRelease(
            fixture,
            files: nativeMutation,
            archiveName: "builder-attested-native-mutation"
        )

        var pythonMutation = fixture.files
        let modulePath = "da3_mps/python/lib/python3.13/site-packages/numpy/__init__.py"
        let replacementModule = Data("__all__ = ['mutated']\n".utf8)
        pythonMutation.base[modulePath] = replacementModule
        var record = try XCTUnwrap(
            String(
                data: pythonMutation.base[ProductionToolchainFileFixture.signedPythonRecordPath]!,
                encoding: .utf8
            )
        )
        let oldRow = try XCTUnwrap(record.split(separator: "\n").first(where: {
            $0.hasPrefix("numpy/__init__.py,")
        }))
        let newRow =
            "numpy/__init__.py,sha256=\(recordHash(replacementModule)),\(replacementModule.count)"
        record.replaceSubrange(try XCTUnwrap(record.range(of: String(oldRow))), with: newRow)
        pythonMutation.base[ProductionToolchainFileFixture.signedPythonRecordPath] = Data(record.utf8)
        try pythonMutation.refreshSupplyChain()
        let pythonRequest = try prepareRelease(
            fixture,
            files: pythonMutation,
            archiveName: "builder-attested-python-mutation"
        )

        for request in [nativeRequest, pythonRequest] {
            XCTAssertNotEqual(
                ManifestBuilder.sha256Hex(data: try ManifestBuilder.canonicalData(for: request)),
                originalDigest
            )
        }
    }

    func testPrepareReleaseRequiresTheCheckedOutSourceCommit() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        XCTAssertThrowsError(
            try ManifestBuilder.prepareRelease(
                repository: repository,
                sourceCommit: String(repeating: "f", count: 40),
                version: version,
                publishedAt: Date(timeIntervalSince1970: 0),
                appVersionRange: appRange,
                publicKeyBase64: fixture.publicKeyBase64,
                components: fixture.inputs
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("exact release source commit"))
        }
    }

    func testReviewedSourceReaderLoadsTrackedBytesFromTheReleaseCommit() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let path = "Tools/Da3Sfm/requirements.txt"

        XCTAssertEqual(
            try ProductionProvenanceValidator.trackedSourceDataForTesting(
                expectedCommit: sourceCommit,
                path: path
            ),
            try Data(contentsOf: root.appendingPathComponent(path))
        )
    }

    func testPrepareReleaseAcceptsOnlySourceBoundFinalizedSigningClosure() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        var files = fixture.files
        try files.finalizeDistributionSigningForTesting()

        XCTAssertNoThrow(
            try prepareRelease(fixture, files: files, archiveName: "finalized-signed")
        )

        var receipt = try jsonObject(files.core["provenance/distribution-signing.json"]!)
        var sourceInputs = try XCTUnwrap(receipt["sourceInputs"] as? [[String: Any]])
        sourceInputs[0]["sha256"] = String(repeating: "0", count: 64)
        receipt["sourceInputs"] = sourceInputs
        files.core["provenance/distribution-signing.json"] = try ProductionToolchainFileFixture.json(receipt)
        try files.refreshSupplyChain()

        XCTAssertThrowsError(
            try prepareRelease(fixture, files: files, archiveName: "forged-signed-source")
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("tracked source-input closure"))
        }
    }

    func testPrepareReleaseRejectsStaleOrIncompleteFinalizedSigningBridges() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let mutations: [(inout [String: Any]) throws -> Void] = [
            { $0["sourceCommit"] = String(repeating: "0", count: 40) },
            { receipt in
                var rows = try XCTUnwrap(receipt["machOFiles"] as? [[String: Any]])
                rows.removeAll { $0["path"] as? String == ProductionToolchainFileFixture.signedPythonMemberPath }
                receipt["machOFiles"] = rows
            },
            { receipt in
                var rows = try XCTUnwrap(receipt["machOFiles"] as? [[String: Any]])
                let index = try XCTUnwrap(rows.firstIndex(where: { $0["path"] as? String == "bin/colmap" }))
                rows[index]["component"] = "msplat"
                receipt["machOFiles"] = rows
            },
            { receipt in
                var rows = try XCTUnwrap(receipt["machOFiles"] as? [[String: Any]])
                let index = try XCTUnwrap(rows.firstIndex(where: { $0["path"] as? String == "bin/colmap" }))
                var provenance = try XCTUnwrap(rows[index]["preSignProvenance"] as? [[String: Any]])
                let buildIndex = try XCTUnwrap(provenance.firstIndex(where: {
                    $0["kind"] as? String == "build-receipt"
                }))
                provenance[buildIndex]["sha256"] = String(repeating: "0", count: 64)
                rows[index]["preSignProvenance"] = provenance
                receipt["machOFiles"] = rows
            },
            { $0["recordRepairs"] = [] },
            { receipt in
                var repairs = try XCTUnwrap(receipt["recordRepairs"] as? [[String: Any]])
                repairs[0]["postRepairSHA256"] = String(repeating: "0", count: 64)
                receipt["recordRepairs"] = repairs
            },
        ]

        for (ordinal, mutation) in mutations.enumerated() {
            var files = fixture.files
            try files.finalizeDistributionSigningForTesting()
            var receipt = try jsonObject(files.core["provenance/distribution-signing.json"]!)
            try mutation(&receipt)
            files.core["provenance/distribution-signing.json"] = try ProductionToolchainFileFixture.json(
                receipt
            )
            try files.refreshSupplyChain()

            XCTAssertThrowsError(
                try prepareRelease(
                    fixture,
                    files: files,
                    archiveName: "stale-finalized-signing-bridge-\(ordinal)"
                )
            )
        }
    }

    func testWriteReleaseSigningRequestAcceptsEightMiBAndRejectsOneByteMore() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let prepared = try prepareRelease(fixture, inputs: fixture.inputs)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let exact = try signingRequest(prepared, encodedSize: 8 * 1_024 * 1_024)
        let exactURL = root.appendingPathComponent("exact-request.json")
        try ManifestBuilder.writeReleaseSigningRequest(exact, to: exactURL)
        XCTAssertEqual(try Data(contentsOf: exactURL).count, 8 * 1_024 * 1_024)

        let oversized = try signingRequest(prepared, encodedSize: 8 * 1_024 * 1_024 + 1)
        let oversizedURL = root.appendingPathComponent("oversized-request.json")
        XCTAssertThrowsError(
            try ManifestBuilder.writeReleaseSigningRequest(oversized, to: oversizedURL)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("8 MiB"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: oversizedURL.path))
    }

    func testPrepareReleaseAcceptsProductionShapedFileClosure() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let files = try productionShapedFiles(
            fixture.files,
            pathSegment: String(repeating: "p", count: 75)
        )

        let supplyChain = try jsonObject(files.core["supply-chain/components.json"]!)
        XCTAssertEqual((supplyChain["components"] as? [[String: Any]])?.count, 63)
        XCTAssertEqual((supplyChain["files"] as? [[String: Any]])?.count, 19_536)

        let request = try prepareRelease(
            fixture,
            files: files,
            archiveName: "production-shaped-request"
        )
        let requestData = try ManifestBuilder.canonicalData(for: request)
        XCTAssertEqual(request.manifest.components.flatMap(\.contents).count, 19_537)
        XCTAssertGreaterThan(requestData.count, 7_500_000)
        XCTAssertLessThanOrEqual(requestData.count, ManifestBuilder.maximumReleaseSigningRequestBytes)
    }

    func testPrepareReleaseRejectsProductionShapedRequestOverAuthorityLimit() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let files = try productionShapedFiles(
            fixture.files,
            pathSegment: String(repeating: "p", count: 95)
        )

        XCTAssertThrowsError(
            try prepareRelease(
                fixture,
                files: files,
                archiveName: "oversized-production-shaped-request"
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("8 MiB"), "\(error)")
        }
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

        XCTAssertThrowsError(try prepareRelease(fixture, inputs: inputs))
    }

    func testPrepareReleaseRejectsUnexpectedCoreAndBasePayloads() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let unexpectedCore = try makeZip(
            named: "unexpected-core",
            files: Dictionary(uniqueKeysWithValues:
                (ManifestToolDefaults.criticalCoreFiles + ["bin/unreviewed-helper"]).map {
                    ($0, Data($0.utf8))
                }
            ),
            in: fixture.root
        )
        var coreInputs = fixture.inputs
        coreInputs[0] = ManifestArtifactInput(
            name: coreInputs[0].name,
            artifactURL: coreInputs[0].artifactURL,
            zipURL: unexpectedCore,
            capabilities: coreInputs[0].capabilities,
            dependencies: coreInputs[0].dependencies,
            requirement: coreInputs[0].requirement,
            criticalFilePaths: coreInputs[0].criticalFilePaths
        )
        XCTAssertThrowsError(try prepareRelease(fixture, inputs: coreInputs))

        let unexpectedBase = try makeZip(
            named: "unexpected-base",
            files: Dictionary(uniqueKeysWithValues:
                (ManifestToolDefaults.da3BaseContents + ["da3_mps/models/DA3-LARGE/model.safetensors"]).map {
                    ($0, Data($0.utf8))
                }
            ),
            in: fixture.root
        )
        var baseInputs = fixture.inputs
        baseInputs[1] = ManifestArtifactInput(
            name: baseInputs[1].name,
            artifactURL: baseInputs[1].artifactURL,
            zipURL: unexpectedBase,
            capabilities: baseInputs[1].capabilities,
            dependencies: baseInputs[1].dependencies,
            requirement: baseInputs[1].requirement,
            criticalFilePaths: baseInputs[1].criticalFilePaths
        )
        XCTAssertThrowsError(try prepareRelease(fixture, inputs: baseInputs))
    }

    func testPrepareReleaseRejectsUnstructuredCurrentProvenanceReceipt() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        var files = fixture.files
        files.core["provenance/colmap.json"] = Data("{}".utf8)
        var supplyChain = try jsonObject(files.core["supply-chain/components.json"]!)
        try replaceSupplyChainFileEvidence(
            in: &supplyChain,
            path: "provenance/colmap.json",
            data: files.core["provenance/colmap.json"]!
        )
        files.core["supply-chain/components.json"] = try ProductionToolchainFileFixture.json(
            supplyChain
        )

        XCTAssertThrowsError(try prepareRelease(fixture, coreFiles: files.core, archiveName: "empty-colmap"))
    }

    func testSignedManifestBuildRejectsUnstructuredCurrentProvenanceReceipt() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        var files = fixture.files
        files.core["provenance/colmap.json"] = Data("{}".utf8)
        var supplyChain = try jsonObject(files.core["supply-chain/components.json"]!)
        try replaceSupplyChainFileEvidence(
            in: &supplyChain,
            path: "provenance/colmap.json",
            data: files.core["provenance/colmap.json"]!
        )
        files.core["supply-chain/components.json"] = try ProductionToolchainFileFixture.json(
            supplyChain
        )
        let core = try makeZip(named: "build-empty-colmap", files: files.core, in: fixture.root)
        var inputs = fixture.inputs
        inputs[0] = ManifestArtifactInput(
            name: inputs[0].name,
            artifactURL: inputs[0].artifactURL,
            zipURL: core,
            capabilities: inputs[0].capabilities,
            dependencies: inputs[0].dependencies,
            requirement: inputs[0].requirement,
            criticalFilePaths: inputs[0].criticalFilePaths
        )

        XCTAssertThrowsError(try fixture.files.withReviewedSourceSnapshot {
            try ManifestBuilder.build(
                version: version,
                publishedAt: Date(timeIntervalSince1970: 0),
                appVersionRange: appRange,
                components: inputs,
                privateKeyBase64: ManifestBuilder.generateKeypair().privateKeyBase64
            )
        })
    }

    func testPrepareReleaseRejectsStaleNativeBinaryAndMetalLibraryHashes() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        for field in ["executable_sha256", "metallib_sha256"] {
            var files = fixture.files
            var receipt = try jsonObject(files.core["msplat/build_info.json"]!)
            receipt[field] = String(repeating: "0", count: 64)
            files.core["msplat/build_info.json"] = try ProductionToolchainFileFixture.json(receipt)
            try files.refreshSupplyChain()

            XCTAssertThrowsError(
                try prepareRelease(fixture, coreFiles: files.core, archiveName: "stale-\(field)")
            )
        }
    }

    func testPrepareReleaseRejectsStaleSupplyChainVersionHashAndSourceClosure() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        let mutations: [(inout [String: Any]) throws -> Void] = [
            { $0["toolchainVersion"] = "2.0.1" },
            { document in
                var files = try XCTUnwrap(document["files"] as? [[String: Any]])
                let index = try XCTUnwrap(files.firstIndex(where: { $0["path"] as? String == "bin/colmap" }))
                files[index]["sha256"] = String(repeating: "0", count: 64)
                document["files"] = files
            },
            { document in
                var components = try XCTUnwrap(document["components"] as? [[String: Any]])
                let index = try XCTUnwrap(components.firstIndex(where: { $0["id"] as? String == "colmap" }))
                components[index]["version"] = "0.0.0-stale"
                document["components"] = components
            },
            { document in
                var components = try XCTUnwrap(document["components"] as? [[String: Any]])
                let index = try XCTUnwrap(components.firstIndex(where: {
                    $0["id"] as? String == "easysplat-da3-runner"
                }))
                components[index]["revision"] = String(repeating: "f", count: 40)
                document["components"] = components
            },
        ]

        for (index, mutate) in mutations.enumerated() {
            var files = fixture.files
            var document = try jsonObject(files.core["supply-chain/components.json"]!)
            try mutate(&document)
            files.core["supply-chain/components.json"] = try ProductionToolchainFileFixture.json(document)

            XCTAssertThrowsError(
                try prepareRelease(fixture, coreFiles: files.core, archiveName: "stale-supply-chain-\(index)")
            )
        }
    }

    func testPrepareReleaseBindsEveryTransitiveSupplyChainIdentityClass() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let mutations: [(inout [[String: Any]]) throws -> Void] = [
            { records in
                let index = try XCTUnwrap(records.firstIndex(where: { $0["id"] as? String == "colmap:faiss" }))
                records[index]["source"] = "https://example.com/fake-faiss.tar.gz"
                records[index]["version"] = "99.99.99"
                records[index]["revision"] = String(repeating: "f", count: 64)
            },
            { records in
                let index = try XCTUnwrap(records.firstIndex(where: { $0["id"] as? String == "msplat:cli11" }))
                records[index]["revision"] = "sha256:\(String(repeating: "0", count: 64))"
            },
            { records in
                let index = try XCTUnwrap(records.firstIndex(where: { $0["id"] as? String == "da3" }))
                records[index]["revision"] = String(repeating: "0", count: 40)
            },
            { records in
                let index = try XCTUnwrap(records.firstIndex(where: { $0["id"] as? String == "model:da3-base" }))
                var artifacts = try XCTUnwrap(records[index]["sourceArtifacts"] as? [[String: Any]])
                artifacts[0]["sha256"] = String(repeating: "0", count: 64)
                records[index]["sourceArtifacts"] = artifacts
            },
            { records in
                let index = try XCTUnwrap(records.firstIndex(where: { $0["id"] as? String == "python:numpy" }))
                records[index]["artifactSha256"] = String(repeating: "0", count: 64)
                records[index]["dependencies"] = ["python:idna"]
            },
            { records in
                let index = try XCTUnwrap(records.firstIndex(where: { $0["id"] as? String == "python-build-standalone" }))
                records[index]["source"] = "https://example.com/fake-python.tar.gz"
            },
            { records in
                let index = try XCTUnwrap(records.firstIndex(where: { $0["id"] as? String == "easysplat-da3-runner" }))
                records[index]["license"] = "Apache-2.0"
                records[index]["dependencies"] = ["da3"]
            },
        ]

        for (index, mutate) in mutations.enumerated() {
            var files = fixture.files
            var document = try jsonObject(files.core["supply-chain/components.json"]!)
            var records = try XCTUnwrap(document["components"] as? [[String: Any]])
            try mutate(&records)
            document["components"] = records
            files.core["supply-chain/components.json"] = try ProductionToolchainFileFixture.json(document)

            XCTAssertThrowsError(
                try prepareRelease(fixture, files: files, archiveName: "transitive-drift-\(index)")
            )
        }
    }

    func testPrepareReleaseRejectsCoupledNativeReceiptAndSupplyChainIdentityMutation() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        var files = fixture.files
        var receipt = try jsonObject(files.core["provenance/colmap.json"]!)
        receipt["source_url"] = "https://attacker.example/colmap.git"
        receipt["source_version"] = "99.0.0"
        receipt["source_commit"] = String(repeating: "d", count: 40)
        let receiptData = try ProductionToolchainFileFixture.json(receipt)
        files.core["provenance/colmap.json"] = receiptData

        var supplyChain = try jsonObject(files.core["supply-chain/components.json"]!)
        var components = try XCTUnwrap(supplyChain["components"] as? [[String: Any]])
        let index = try XCTUnwrap(components.firstIndex(where: { $0["id"] as? String == "colmap" }))
        components[index]["source"] = receipt["source_url"]
        components[index]["version"] = receipt["source_version"]
        components[index]["revision"] = receipt["source_commit"]
        supplyChain["components"] = components
        try replaceSupplyChainFileEvidence(
            in: &supplyChain,
            path: "provenance/colmap.json",
            data: receiptData
        )
        files.core["supply-chain/components.json"] = try ProductionToolchainFileFixture.json(supplyChain)

        XCTAssertThrowsError(
            try prepareRelease(fixture, files: files, archiveName: "coupled-native-identity")
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("reviewed source lock"), "\(error)")
        }
    }

    func testPrepareReleaseRejectsCoupledNativeDependencyReceiptMutations() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let cases: [(receipt: String, dependency: String?, component: String)] = [
            ("provenance/colmap.json", "faiss", "colmap:faiss"),
            ("provenance/colmap-support.json", "boost", "colmap-support:boost"),
            ("provenance/ceres.json", "eigen", "ceres:eigen"),
            ("provenance/openimageio.json", "fmt", "openimageio:fmt"),
            ("msplat/build_info.json", nil, "msplat"),
        ]

        for (ordinal, item) in cases.enumerated() {
            var files = fixture.files
            var receipt = try jsonObject(files.core[item.receipt]!)
            if let dependencyName = item.dependency {
                var dependencies = try XCTUnwrap(receipt["dependencies"] as? [String: [String: Any]])
                var dependency = try XCTUnwrap(dependencies[dependencyName])
                dependency["source_url"] = "https://attacker.example/dependency.tar.gz"
                dependency["source_version"] = "99.0.0"
                if dependency["source_commit"] != nil {
                    dependency["source_commit"] = String(repeating: "d", count: 40)
                }
                if dependency["source_sha256"] != nil {
                    dependency["source_sha256"] = String(repeating: "d", count: 64)
                }
                if dependency["source_archive_sha256"] != nil {
                    dependency["source_archive_sha256"] = String(repeating: "d", count: 64)
                }
                dependencies[dependencyName] = dependency
                receipt["dependencies"] = dependencies
            } else {
                receipt["source_url"] = "https://attacker.example/msplat.git"
                receipt["source_version"] = "99.0.0"
                receipt["source_commit"] = String(repeating: "d", count: 40)
            }
            let receiptData = try ProductionToolchainFileFixture.json(receipt)
            files.core[item.receipt] = receiptData

            var supplyChain = try jsonObject(files.core["supply-chain/components.json"]!)
            var components = try XCTUnwrap(supplyChain["components"] as? [[String: Any]])
            let componentIndex = try XCTUnwrap(components.firstIndex(where: {
                $0["id"] as? String == item.component
            }))
            components[componentIndex]["source"] = "https://attacker.example/dependency.tar.gz"
            components[componentIndex]["version"] = "99.0.0"
            let currentRevision = try XCTUnwrap(components[componentIndex]["revision"] as? String)
            components[componentIndex]["revision"] = currentRevision.hasPrefix("sha256:")
                ? "sha256:\(String(repeating: "d", count: 64))"
                : String(repeating: "d", count: currentRevision.count)
            if components[componentIndex]["artifact"] != nil {
                components[componentIndex]["artifact"] = "https://attacker.example/dependency.tar.gz"
                components[componentIndex]["artifactSha256"] = String(repeating: "d", count: 64)
            }
            supplyChain["components"] = components
            try replaceSupplyChainFileEvidence(in: &supplyChain, path: item.receipt, data: receiptData)
            files.core["supply-chain/components.json"] = try ProductionToolchainFileFixture.json(supplyChain)

            XCTAssertThrowsError(
                try prepareRelease(
                    fixture,
                    files: files,
                    archiveName: "coupled-native-dependency-\(ordinal)"
                )
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("reviewed source lock"), "\(error)")
            }
        }
    }

    func testPrepareReleaseRejectsReceiptControlledNativeDependencyArtifacts() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let cases: [(url: String, digest: String?)] = [
            ("https://attacker.example/faiss.zip?token=secret", String(repeating: "f", count: 64)),
            ("https://attacker.example/faiss.zip", nil),
            ("https://attacker.example/faiss.zip", String(repeating: "f", count: 64)),
        ]

        for (ordinal, item) in cases.enumerated() {
            var files = fixture.files
            var receipt = try jsonObject(files.core["provenance/colmap.json"]!)
            var dependencies = try XCTUnwrap(receipt["dependencies"] as? [String: [String: Any]])
            var dependency = try XCTUnwrap(dependencies["faiss"])
            dependency["artifact_url"] = item.url
            if let digest = item.digest {
                dependency["artifact_sha256"] = digest
            }
            dependencies["faiss"] = dependency
            receipt["dependencies"] = dependencies
            files.core["provenance/colmap.json"] = try ProductionToolchainFileFixture.json(receipt)
            try files.refreshSupplyChain()
            var supplyChain = try jsonObject(files.core["supply-chain/components.json"]!)
            var components = try XCTUnwrap(supplyChain["components"] as? [[String: Any]])
            let componentIndex = try XCTUnwrap(components.firstIndex(where: {
                $0["id"] as? String == "colmap:faiss"
            }))
            components[componentIndex]["artifact"] = item.url
            components[componentIndex]["artifactSha256"] = item.digest ?? ""
            supplyChain["components"] = components
            files.core["supply-chain/components.json"] = try ProductionToolchainFileFixture.json(
                supplyChain
            )

            XCTAssertThrowsError(
                try prepareRelease(
                    fixture,
                    files: files,
                    archiveName: "receipt-controlled-native-artifact-\(ordinal)"
                )
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("artifact"), "\(error)")
            }
        }
    }

    func testPrepareReleaseRejectsMixedNativeDependencyArtifactFieldFamilies() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let cases: [(inout [String: Any]) -> Void] = [
            { dependency in
                dependency["source_archive_sha256"] = String(repeating: "e", count: 64)
            },
            { dependency in
                let source = dependency["source_url"]
                let digest = dependency.removeValue(forKey: "source_sha256")
                dependency["source_archive_url"] = source
                dependency["source_archive_sha256"] = digest
                dependency["artifact_sha256"] = String(repeating: "e", count: 64)
            },
        ]

        for (ordinal, mutation) in cases.enumerated() {
            var files = fixture.files
            var receipt = try jsonObject(files.core["provenance/colmap.json"]!)
            var dependencies = try XCTUnwrap(receipt["dependencies"] as? [String: [String: Any]])
            var dependency = try XCTUnwrap(dependencies["faiss"])
            mutation(&dependency)
            dependencies["faiss"] = dependency
            receipt["dependencies"] = dependencies
            files.core["provenance/colmap.json"] = try ProductionToolchainFileFixture.json(receipt)
            try files.refreshSupplyChain()

            var supplyChain = try jsonObject(files.core["supply-chain/components.json"]!)
            var components = try XCTUnwrap(supplyChain["components"] as? [[String: Any]])
            let componentIndex = try XCTUnwrap(components.firstIndex(where: {
                $0["id"] as? String == "colmap:faiss"
            }))
            components[componentIndex]["artifact"] = dependency["source_url"]
            components[componentIndex]["artifactSha256"] =
                dependency["artifact_sha256"] ?? dependency["source_archive_sha256"]
            supplyChain["components"] = components
            files.core["supply-chain/components.json"] = try ProductionToolchainFileFixture.json(
                supplyChain
            )

            XCTAssertThrowsError(
                try prepareRelease(
                    fixture,
                    files: files,
                    archiveName: "mixed-native-artifact-fields-\(ordinal)"
                )
            ) { error in
                XCTAssertTrue(error.localizedDescription.contains("artifact"), "\(error)")
            }
        }
    }

    func testPrepareReleaseRejectsArtifactMetadataForVendoredSourceTrees() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let cases: [(inout [String: Any]) -> Void] = [
            { dependency in
                dependency["artifact_url"] = dependency["source_url"]
                dependency["artifact_sha256"] = dependency["source_tree_sha256"]
            },
            { dependency in
                let digest = dependency.removeValue(forKey: "source_tree_sha256")
                dependency["source_archive_url"] = dependency["source_url"]
                dependency["source_archive_sha256"] = digest
            },
            { dependency in
                dependency.removeValue(forKey: "source_tree_sha256")
                dependency["source_sha256"] = String(repeating: "e", count: 64)
                dependency["artifact_url"] = dependency["source_url"]
                dependency["artifact_sha256"] = dependency["source_sha256"]
            },
        ]

        for (ordinal, mutation) in cases.enumerated() {
            var files = fixture.files
            var receipt = try jsonObject(files.core["provenance/colmap.json"]!)
            var dependencies = try XCTUnwrap(receipt["dependencies"] as? [String: [String: Any]])
            var dependency = try XCTUnwrap(dependencies["vlfeat"])
            mutation(&dependency)
            dependencies["vlfeat"] = dependency
            receipt["dependencies"] = dependencies
            files.core["provenance/colmap.json"] = try ProductionToolchainFileFixture.json(receipt)
            try files.refreshSupplyChain()

            var supplyChain = try jsonObject(files.core["supply-chain/components.json"]!)
            var components = try XCTUnwrap(supplyChain["components"] as? [[String: Any]])
            let componentIndex = try XCTUnwrap(components.firstIndex(where: {
                $0["id"] as? String == "colmap:vlfeat"
            }))
            components[componentIndex]["artifact"] = dependency["source_url"]
            components[componentIndex]["artifactSha256"] =
                dependency["artifact_sha256"] ?? dependency["source_archive_sha256"]
            supplyChain["components"] = components
            files.core["supply-chain/components.json"] = try ProductionToolchainFileFixture.json(
                supplyChain
            )

            XCTAssertThrowsError(
                try prepareRelease(
                    fixture,
                    files: files,
                    archiveName: "vendored-tree-artifact-\(ordinal)"
                )
            ) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains("archive")
                        || error.localizedDescription.contains("artifact"),
                    "\(error)"
                )
            }
        }
    }

    func testPrepareReleaseRejectsCoupledDA3ReceiptAndSupplyChainIdentityMutation() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        var files = fixture.files
        var receipt = try jsonObject(files.base["da3_mps/build_info.json"]!)
        let commit = String(repeating: "e", count: 40)
        let repository = "https://attacker.example/depth-anything-3.git"
        receipt["source_repo"] = repository
        receipt["expected_upstream_repo"] = repository
        receipt["source_ref"] = commit
        receipt["source_commit"] = commit
        receipt["expected_upstream_ref"] = commit
        receipt["source_path"] = "git:\(repository)@\(commit)"
        let receiptData = try ProductionToolchainFileFixture.json(receipt)
        files.base["da3_mps/build_info.json"] = receiptData

        var supplyChain = try jsonObject(files.core["supply-chain/components.json"]!)
        var components = try XCTUnwrap(supplyChain["components"] as? [[String: Any]])
        let index = try XCTUnwrap(components.firstIndex(where: { $0["id"] as? String == "da3" }))
        components[index]["source"] = repository
        components[index]["version"] = commit
        components[index]["revision"] = commit
        supplyChain["components"] = components
        try replaceSupplyChainFileEvidence(
            in: &supplyChain,
            path: "da3_mps/build_info.json",
            data: receiptData
        )
        files.core["supply-chain/components.json"] = try ProductionToolchainFileFixture.json(supplyChain)

        XCTAssertThrowsError(
            try prepareRelease(fixture, files: files, archiveName: "coupled-da3-identity")
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("reviewed source lock"), "\(error)")
        }
    }

    func testPrepareReleaseRejectsUnreportedInstalledPythonDistribution() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        var files = fixture.files
        let prefix = "da3_mps/python/lib/python3.13/site-packages"
        files.base["\(prefix)/evilpkg-9.9.9.dist-info/METADATA"] = Data("""
        Metadata-Version: 2.4
        Name: evilpkg
        Version: 9.9.9
        License-Expression: MIT

        """.utf8)
        files.base["\(prefix)/evilpkg-9.9.9.dist-info/RECORD"] = Data("".utf8)
        files.base["\(prefix)/evilpkg/__init__.py"] = Data("owned = false\n".utf8)
        try files.refreshSupplyChain()

        XCTAssertThrowsError(
            try prepareRelease(fixture, files: files, archiveName: "unreported-python-distribution")
        )
    }

    func testPrepareReleaseRejectsUnownedSitePackagesFile() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        var files = fixture.files
        files.base[
            "da3_mps/python/lib/python3.13/site-packages/injected_runtime.py"
        ] = Data("unowned = true\n".utf8)
        try files.refreshSupplyChain()

        XCTAssertThrowsError(
            try prepareRelease(fixture, files: files, archiveName: "unowned-site-packages")
        )

        var secondRoot = fixture.files
        secondRoot.base[
            "da3_mps/python/lib/python3.12/site-packages/injected_runtime.py"
        ] = Data("unowned = true\n".utf8)
        try secondRoot.refreshSupplyChain()

        XCTAssertThrowsError(
            try prepareRelease(fixture, files: secondRoot, archiveName: "second-site-packages-root")
        )
    }

    func testPrepareReleaseRejectsPythonRecordHashMismatch() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        var files = fixture.files
        files.base[
            "da3_mps/python/lib/python3.13/site-packages/numpy/__init__.py"
        ] = Data("tampered = true\n".utf8)
        try files.refreshSupplyChain()

        XCTAssertThrowsError(
            try prepareRelease(fixture, files: files, archiveName: "python-record-hash-mismatch")
        )

        var aliasedRecord = fixture.files
        let recordPath = "da3_mps/python/lib/python3.13/site-packages/numpy-2.3.5.dist-info/RECORD"
        let record = String(decoding: aliasedRecord.base[recordPath]!, as: UTF8.self)
            .replacingOccurrences(of: "numpy/__init__.py", with: "numpy//__init__.py")
        aliasedRecord.base[recordPath] = Data(record.utf8)
        try aliasedRecord.refreshSupplyChain()

        XCTAssertThrowsError(
            try prepareRelease(fixture, files: aliasedRecord, archiveName: "aliased-python-record")
        )
    }

    func testPrepareReleaseRejectsCredentialBearingProvenanceURLQuery() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        var files = fixture.files
        let reportPath = "da3_mps/licenses/python-packages-install-report.json"
        var report = try jsonObject(files.base[reportPath]!)
        var installs = try XCTUnwrap(report["install"] as? [[String: Any]])
        let index = try XCTUnwrap(installs.firstIndex(where: {
            (($0["metadata"] as? [String: Any])?["name"] as? String) == "numpy"
        }))
        var download = try XCTUnwrap(installs[index]["download_info"] as? [String: Any])
        download["url"] = "https://files.pythonhosted.org/numpy.whl?token=secret"
        installs[index]["download_info"] = download
        report["install"] = installs
        let reportData = try ProductionToolchainFileFixture.json(report)
        files.base[reportPath] = reportData

        var supplyChain = try jsonObject(files.core["supply-chain/components.json"]!)
        var components = try XCTUnwrap(supplyChain["components"] as? [[String: Any]])
        let componentIndex = try XCTUnwrap(components.firstIndex(where: {
            $0["id"] as? String == "python:numpy"
        }))
        components[componentIndex]["artifact"] = download["url"]
        supplyChain["components"] = components
        try replaceSupplyChainFileEvidence(in: &supplyChain, path: reportPath, data: reportData)
        files.core["supply-chain/components.json"] = try ProductionToolchainFileFixture.json(supplyChain)

        XCTAssertThrowsError(
            try prepareRelease(fixture, files: files, archiveName: "credential-query-url")
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("artifact"), "\(error)")
        }
    }

    func testPrepareReleaseUsesPathSpecificProvenanceReceiptLimits() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        var exactGeneric = fixture.files
        exactGeneric.core["msplat/build_info.json"] = try paddedJSON(
            exactGeneric.core["msplat/build_info.json"]!,
            to: 1 * 1_024 * 1_024
        )
        try exactGeneric.refreshSupplyChain()
        XCTAssertNoThrow(
            try prepareRelease(fixture, files: exactGeneric, archiveName: "exact-generic-receipt")
        )

        var oversizedGeneric = fixture.files
        oversizedGeneric.core["msplat/build_info.json"] = try paddedJSON(
            oversizedGeneric.core["msplat/build_info.json"]!,
            to: 1 * 1_024 * 1_024 + 1
        )
        try oversizedGeneric.refreshSupplyChain()
        XCTAssertThrowsError(
            try prepareRelease(fixture, files: oversizedGeneric, archiveName: "oversized-generic-receipt")
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("1 MiB"))
        }

        var exactSupplyChain = fixture.files
        exactSupplyChain.core["supply-chain/components.json"] = try paddedJSON(
            exactSupplyChain.core["supply-chain/components.json"]!,
            to: 16 * 1_024 * 1_024
        )
        XCTAssertNoThrow(
            try prepareRelease(fixture, files: exactSupplyChain, archiveName: "exact-supply-chain")
        )

        var oversizedSupplyChain = fixture.files
        oversizedSupplyChain.core["supply-chain/components.json"] = try paddedJSON(
            oversizedSupplyChain.core["supply-chain/components.json"]!,
            to: 16 * 1_024 * 1_024 + 1
        )
        XCTAssertThrowsError(
            try prepareRelease(fixture, files: oversizedSupplyChain, archiveName: "oversized-supply-chain")
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("16 MiB"))
        }
    }

    func testPrepareReleaseBindsDA3LocksModelsAndPythonInstallReport() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        var staleBuildInfo = fixture.files
        var buildInfo = try jsonObject(staleBuildInfo.base["da3_mps/build_info.json"]!)
        buildInfo["requirements_lock_sha256"] = String(repeating: "0", count: 64)
        staleBuildInfo.base["da3_mps/build_info.json"] = try ProductionToolchainFileFixture.json(buildInfo)
        try staleBuildInfo.refreshSupplyChain()
        XCTAssertThrowsError(
            try prepareRelease(fixture, files: staleBuildInfo, archiveName: "stale-da3-build-info")
        )

        var staleModel = fixture.files
        var model = try jsonObject(staleModel.base["da3_mps/models/DA3-BASE/easysplat_model_info.json"]!)
        model["resolved_sha"] = String(repeating: "0", count: 40)
        staleModel.base["da3_mps/models/DA3-BASE/easysplat_model_info.json"] =
            try ProductionToolchainFileFixture.json(model)
        try staleModel.refreshSupplyChain()
        XCTAssertThrowsError(
            try prepareRelease(fixture, files: staleModel, archiveName: "stale-da3-model")
        )

        var substitutedModel = fixture.files
        let modelPath = "da3_mps/models/DA3-BASE/model.safetensors"
        let infoPath = "da3_mps/models/DA3-BASE/easysplat_model_info.json"
        let replacement = Data("replacement-model-weights".utf8)
        substitutedModel.base[modelPath] = replacement
        var substitutedInfo = try jsonObject(substitutedModel.base[infoPath]!)
        var artifacts = try XCTUnwrap(substitutedInfo["artifacts"] as? [String: [String: Any]])
        artifacts["model.safetensors"] = [
            "sha256": ProductionToolchainFileFixture.sha256(replacement),
            "size_bytes": replacement.count,
        ]
        substitutedInfo["artifacts"] = artifacts
        substitutedModel.base[infoPath] = try ProductionToolchainFileFixture.json(substitutedInfo)
        try substitutedModel.refreshSupplyChain()
        XCTAssertThrowsError(
            try prepareRelease(fixture, files: substitutedModel, archiveName: "substituted-da3-model")
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("model artifact closure"), "\(error)")
        }

        var staleReport = fixture.files
        var report = try jsonObject(staleReport.base["da3_mps/licenses/python-packages-install-report.json"]!)
        var install = try XCTUnwrap(report["install"] as? [[String: Any]])
        var download = try XCTUnwrap(install[0]["download_info"] as? [String: Any])
        var archive = try XCTUnwrap(download["archive_info"] as? [String: Any])
        archive["hashes"] = ["sha256": String(repeating: "0", count: 64)]
        download["archive_info"] = archive
        install[0]["download_info"] = download
        report["install"] = install
        staleReport.base["da3_mps/licenses/python-packages-install-report.json"] =
            try ProductionToolchainFileFixture.json(report)
        try staleReport.refreshSupplyChain()
        XCTAssertThrowsError(
            try prepareRelease(fixture, files: staleReport, archiveName: "stale-python-report")
        )
    }

    func testPrepareReleaseRejectsDuplicateAndMissingSupplyChainRecords() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        for duplicate in [true, false] {
            var files = fixture.files
            var document = try jsonObject(files.core["supply-chain/components.json"]!)
            var components = try XCTUnwrap(document["components"] as? [[String: Any]])
            if duplicate {
                components.append(try XCTUnwrap(components.first(where: { $0["id"] as? String == "colmap" })))
            } else {
                components.removeAll(where: { $0["id"] as? String == "msplat" })
            }
            document["components"] = components
            files.core["supply-chain/components.json"] = try ProductionToolchainFileFixture.json(document)

            XCTAssertThrowsError(try prepareRelease(
                fixture,
                coreFiles: files.core,
                archiveName: duplicate ? "duplicate-component" : "missing-component"
            ))
        }
    }

    func testReleaseCommandArgumentsRejectUnknownAndDuplicateOptions() throws {
        let unknown = ArgParser(["--request", "request.json", "--archive", "payload.zip"])
        XCTAssertThrowsError(try unknown.requireOnly(["--request"]))

        let duplicate = ArgParser(["--request", "first.json", "--request", "second.json"])
        XCTAssertThrowsError(try duplicate.requireOnly(["--request"]))

        let exact = ArgParser(["--request-out", "request.json", "--version", version])
        XCTAssertNoThrow(try exact.requireOnly(["--request-out", "--version"]))
    }

    func testDirectSigningRejectsProductionReleaseComponents() throws {
        let urls = ManifestBuilder.releaseComponentURLs(
            repository: repository,
            version: version
        )

        XCTAssertThrowsError(
            try ManifestBuilder.requireDirectSigningAllowed(
                components: directSigningInputs(urls: urls)
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("prepare-release"), "\(error)")
        }
    }

    func testDirectSigningAllowsExplicitLoopbackDevelopmentComponents() throws {
        XCTAssertNoThrow(
            try ManifestBuilder.requireDirectSigningAllowed(
                components: directSigningInputs(urls: [
                    "macos-arm64-core": "http://localhost:8000/core.zip",
                    "geometry-da3-base": "http://127.0.0.1:8000/base.zip",
                    "geometry-da3-small": "http://[::1]:8000/small.zip",
                ])
            )
        )
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let files = try ProductionToolchainFileFixture(
            version: version,
            sourceRepository: repository,
            sourceCommit: sourceCommit
        )
        let core = try makeZip(
            named: "core",
            files: files.core,
            in: root
        )
        let base = try makeZip(
            named: "base",
            files: files.base,
            in: root
        )
        let small = try makeZip(
            named: "small",
            files: files.small,
            in: root
        )
        let publicKeyBase64 = ManifestBuilder.generateKeypair().publicKeyBase64
        let urls = ManifestBuilder.releaseComponentURLs(repository: repository, version: version)
        return Fixture(
            root: root,
            publicKeyBase64: publicKeyBase64,
            files: files,
            inputs: [
                .init(name: "macos-arm64-core", artifactURL: urls["macos-arm64-core"]!, zipURL: core, capabilities: ManifestToolDefaults.coreCapabilities, dependencies: [], requirement: .required, criticalFilePaths: ManifestToolDefaults.criticalCoreFiles),
                .init(name: "geometry-da3-base", artifactURL: urls["geometry-da3-base"]!, zipURL: base, capabilities: ["geometry.da3.runtime", "geometry.da3.base"], dependencies: ["macos-arm64-core"], requirement: .optional, criticalFilePaths: ManifestToolDefaults.da3BaseContents),
                .init(name: "geometry-da3-small", artifactURL: urls["geometry-da3-small"]!, zipURL: small, capabilities: ["geometry.da3.small"], dependencies: ["geometry-da3-base"], requirement: .optional, criticalFilePaths: ManifestToolDefaults.da3SmallContents),
            ]
        )
    }

    private func directSigningInputs(urls: [String: String]) -> [ManifestArtifactInput] {
        let unusedArchive = URL(fileURLWithPath: "/tmp/unused-manifest-tool-test.zip")
        return [
            .init(
                name: "macos-arm64-core",
                artifactURL: urls["macos-arm64-core"]!,
                zipURL: unusedArchive,
                capabilities: ManifestToolDefaults.coreCapabilities,
                dependencies: [],
                requirement: .required,
                criticalFilePaths: ManifestToolDefaults.criticalCoreFiles
            ),
            .init(
                name: "geometry-da3-base",
                artifactURL: urls["geometry-da3-base"]!,
                zipURL: unusedArchive,
                capabilities: ["geometry.da3.runtime", "geometry.da3.base"],
                dependencies: ["macos-arm64-core"],
                requirement: .optional,
                criticalFilePaths: ManifestToolDefaults.da3BaseContents
            ),
            .init(
                name: "geometry-da3-small",
                artifactURL: urls["geometry-da3-small"]!,
                zipURL: unusedArchive,
                capabilities: ["geometry.da3.small"],
                dependencies: ["geometry-da3-base"],
                requirement: .optional,
                criticalFilePaths: ManifestToolDefaults.da3SmallContents
            ),
        ]
    }

    private func prepareRelease(
        _ fixture: Fixture,
        coreFiles: [String: Data],
        archiveName: String
    ) throws -> ReleaseSigningRequest {
        var files = fixture.files
        files.core = coreFiles
        return try prepareRelease(fixture, files: files, archiveName: archiveName)
    }

    private func prepareRelease(
        _ fixture: Fixture,
        files: ProductionToolchainFileFixture,
        archiveName: String
    ) throws -> ReleaseSigningRequest {
        let core = try makeZip(named: "\(archiveName)-core", files: files.core, in: fixture.root)
        let base = try makeZip(named: "\(archiveName)-base", files: files.base, in: fixture.root)
        let small = try makeZip(named: "\(archiveName)-small", files: files.small, in: fixture.root)
        var inputs = fixture.inputs
        inputs[0] = ManifestArtifactInput(
            name: inputs[0].name,
            artifactURL: inputs[0].artifactURL,
            zipURL: core,
            capabilities: inputs[0].capabilities,
            dependencies: inputs[0].dependencies,
            requirement: inputs[0].requirement,
            criticalFilePaths: inputs[0].criticalFilePaths
        )
        inputs[1] = ManifestArtifactInput(
            name: inputs[1].name,
            artifactURL: inputs[1].artifactURL,
            zipURL: base,
            capabilities: inputs[1].capabilities,
            dependencies: inputs[1].dependencies,
            requirement: inputs[1].requirement,
            criticalFilePaths: inputs[1].criticalFilePaths
        )
        inputs[2] = ManifestArtifactInput(
            name: inputs[2].name,
            artifactURL: inputs[2].artifactURL,
            zipURL: small,
            capabilities: inputs[2].capabilities,
            dependencies: inputs[2].dependencies,
            requirement: inputs[2].requirement,
            criticalFilePaths: inputs[2].criticalFilePaths
        )
        return try fixture.files.withReviewedSourceSnapshot {
            try buildReleaseRequest(fixture, inputs: inputs)
        }
    }

    private func prepareRelease(
        _ fixture: Fixture,
        inputs: [ManifestArtifactInput]
    ) throws -> ReleaseSigningRequest {
        try fixture.files.withReviewedSourceSnapshot {
            try buildReleaseRequest(fixture, inputs: inputs)
        }
    }

    private func buildReleaseRequest(
        _ fixture: Fixture,
        inputs: [ManifestArtifactInput]
    ) throws -> ReleaseSigningRequest {
        try ManifestBuilder.prepareRelease(
            repository: repository,
            sourceCommit: sourceCommit,
            version: version,
            publishedAt: Date(timeIntervalSince1970: 0),
            appVersionRange: appRange,
            publicKeyBase64: fixture.publicKeyBase64,
            components: inputs
        )
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func paddedJSON(_ data: Data, to size: Int) throws -> Data {
        guard data.count <= size else {
            throw NSError(domain: "ReleaseSigningTests", code: 3)
        }
        var result = data
        result.append(Data(repeating: 0x20, count: size - data.count))
        return result
    }

    private func replaceSupplyChainFileEvidence(
        in document: inout [String: Any],
        path: String,
        data: Data
    ) throws {
        var files = try XCTUnwrap(document["files"] as? [[String: Any]])
        let index = try XCTUnwrap(files.firstIndex(where: { $0["path"] as? String == path }))
        files[index]["sha256"] = ProductionToolchainFileFixture.sha256(data)
        files[index]["size"] = data.count
        document["files"] = files
    }

    private func signingRequest(
        _ request: ReleaseSigningRequest,
        encodedSize: Int
    ) throws -> ReleaseSigningRequest {
        var probe = request
        probe.manifest.components[0].capabilities.append("")
        let probeSize = try ManifestBuilder.canonicalData(for: probe).count
        guard encodedSize >= probeSize else {
            throw NSError(domain: "ReleaseSigningTests", code: 2)
        }
        probe.manifest.components[0].capabilities[probe.manifest.components[0].capabilities.count - 1]
            = String(repeating: "x", count: encodedSize - probeSize)
        XCTAssertEqual(try ManifestBuilder.canonicalData(for: probe).count, encodedSize)
        return probe
    }

    private func productionShapedFiles(
        _ original: ProductionToolchainFileFixture,
        pathSegment: String
    ) throws -> ProductionToolchainFileFixture {
        var files = original
        let currentCount = files.core.count + files.base.count + files.small.count - 1
        for index in 0..<(19_536 - currentCount) {
            let path = String(
                format:
                    "licenses/production-shape-%02d/%@/representative-python-runtime-payload-data-file-%05d.txt",
                index % 32,
                pathSegment,
                index
            )
            files.core[path] = Data([UInt8(index % 251)])
        }
        try files.refreshSupplyChain()
        return files
    }

    private func recordHash(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
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
        let stdin = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = source
        process.arguments = ["-q", zip.path, "-@"]
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data((files.keys.sorted().joined(separator: "\n") + "\n").utf8))
        try stdin.fileHandleForWriting.close()
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
    let files: ProductionToolchainFileFixture
    let inputs: [ManifestArtifactInput]

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
