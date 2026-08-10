import Foundation
import XCTest

enum ReleaseReliabilityFixtureSupport {
    static let fixtureRootKey = "EASYSPLAT_RELEASE_RELIABILITY_FIXTURE_ROOT"
    static let outputRootKey = "EASYSPLAT_RELEASE_RELIABILITY_OUTPUT_ROOT"
    static let receiptKey = "EASYSPLAT_RELEASE_RELIABILITY_RECEIPT"
    static let workloadKey = "EASYSPLAT_RELEASE_RELIABILITY_WORKLOAD"
    static let timingKey = "EASYSPLAT_RELEASE_RELIABILITY_TIMING"

    static var requiresTimingAssertions: Bool {
        ProcessInfo.processInfo.environment[timingKey] == "1"
    }

    struct Context {
        let fixtureRoot: URL
        let outputRoot: URL
        let receiptURL: URL
        let workload: String
        let manifest: Manifest

        func recordSuccess(elapsed: Duration) throws {
            try ReleaseReliabilityFixtureSupport.writeSuccessReceipt(
                to: receiptURL,
                workload: workload,
                elapsed: elapsed
            )
        }
    }

    struct Manifest: Decodable {
        let entryCount: Int
        let ply: Ply
        let zip: Zip

        struct Ply: Decodable {
            let byteCount: UInt64
            let format: String
            let gaussianCount: Int
            let sceneBounds: SceneBounds
            let sha256: String
            let targetMiB: Double

            struct SceneBounds: Decodable {
                let center: Center
                let radius: Double

                struct Center: Decodable {
                    let x: Double
                    let y: Double
                    let z: Double
                }
            }
        }

        struct Zip: Decodable {
            let entryCount: Int
            let largeEntryPath: String
            let largeEntrySHA256: String
            let uncompressedByteCount: UInt64
        }
    }

    static func recordRequiredTimingCheck(
        workload expectedWorkload: String,
        elapsed: Duration
    ) throws {
        guard requiresTimingAssertions else { return }
        let environment = ProcessInfo.processInfo.environment
        guard let receiptPath = environment[receiptKey],
              let workload = environment[workloadKey] else {
            XCTFail("The release timing receipt environment is incomplete.")
            throw CocoaError(.fileWriteUnknown)
        }
        XCTAssertEqual(workload, expectedWorkload)
        guard workload == expectedWorkload else {
            throw CocoaError(.fileWriteUnknown)
        }
        try writeSuccessReceipt(
            to: URL(fileURLWithPath: receiptPath),
            workload: workload,
            elapsed: elapsed
        )
    }

    private static func writeSuccessReceipt(
        to receiptURL: URL,
        workload: String,
        elapsed: Duration
    ) throws {
        let components = elapsed.components
        let wallSeconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        XCTAssertTrue(wallSeconds.isFinite && wallSeconds > 0)
        guard wallSeconds.isFinite, wallSeconds > 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        let payload = Data(
            "{\"schemaVersion\":1,\"status\":\"passed\",\"wallSeconds\":\(wallSeconds),\"workload\":\"\(workload)\"}\n".utf8
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: receiptURL.path),
            "The release workload receipt must be created exactly once."
        )
        try payload.write(to: receiptURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: receiptURL.path
        )
    }

    static func load(workload expectedWorkload: String) throws -> Context {
        let environment = ProcessInfo.processInfo.environment
        guard let fixtureRootPath = environment[fixtureRootKey],
              let outputRootPath = environment[outputRootKey],
              let receiptPath = environment[receiptKey],
              let workload = environment[workloadKey] else {
            throw XCTSkip(
                "The authenticated release-reliability fixture environment is not active."
            )
        }
        XCTAssertEqual(workload, expectedWorkload)
        guard workload == expectedWorkload else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let fixtureRoot = URL(fileURLWithPath: fixtureRootPath, isDirectory: true)
        let outputRoot = URL(fileURLWithPath: outputRootPath, isDirectory: true)
        let receiptURL = URL(fileURLWithPath: receiptPath)
        let manifestURL = fixtureRoot.appendingPathComponent("fixture-manifest.json")
        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: manifestURL, options: .mappedIfSafe)
        )
        return Context(
            fixtureRoot: fixtureRoot,
            outputRoot: outputRoot,
            receiptURL: receiptURL,
            workload: workload,
            manifest: manifest
        )
    }
}
