#if canImport(XCTest)
import Foundation
import XCTest
import SQLite3
@testable import EasySplatCore

final class DescriptorMatcherRecoveryTests: XCTestCase {
    func testFaissMatcherSignalSelectsExactRecovery() {
        let error = ColmapRunnerError.failed(
            command: "matches_importer",
            exitCode: SIGSEGV,
            terminationReason: .uncaughtSignal,
            stdoutTail: "",
            stderrTail: "segmentation fault"
        )

        XCTAssertEqual(
            DescriptorMatcherRecoveryPolicy.reason(
                for: error,
                currentMatcher: .faiss
            ),
            .faissCrash
        )
    }

    func testCancellationSignalsDoNotSelectExactRecovery() {
        for signal in [Int32(SIGTERM), Int32(SIGKILL)] {
            let error = ColmapRunnerError.failed(
                command: "matches_importer",
                exitCode: signal,
                terminationReason: .uncaughtSignal,
                stdoutTail: "",
                stderrTail: "terminated"
            )

            XCTAssertNil(
                DescriptorMatcherRecoveryPolicy.reason(
                    for: error,
                    currentMatcher: .faiss
                ),
                "signal \(signal) must remain a cancellation instead of starting recovery"
            )
        }
    }

    func testFaissUnsupportedOperationSelectsExactRecovery() {
        let error = ColmapRunnerError.failed(
            command: "matches_importer",
            exitCode: 1,
            terminationReason: .exit,
            stdoutTail: "",
            stderrTail: "Feature descriptor index not implemented"
        )

        XCTAssertEqual(
            DescriptorMatcherRecoveryPolicy.reason(
                for: error,
                currentMatcher: .faiss
            ),
            .faissUnsupportedOperation
        )
    }

    func testGenericUnsupportedOperationDoesNotSelectExactRecovery() {
        let error = ColmapRunnerError.failed(
            command: "matches_importer",
            exitCode: 1,
            terminationReason: .exit,
            stdoutTail: "",
            stderrTail: "filesystem returned unsupported operation"
        )

        XCTAssertNil(
            DescriptorMatcherRecoveryPolicy.reason(
                for: error,
                currentMatcher: .faiss
            )
        )
    }

    func testGenericFailureDoesNotSelectExactRecovery() {
        let error = ColmapRunnerError.failed(
            command: "matches_importer",
            exitCode: 1,
            terminationReason: .exit,
            stdoutTail: "",
            stderrTail: "database is locked"
        )

        XCTAssertNil(
            DescriptorMatcherRecoveryPolicy.reason(
                for: error,
                currentMatcher: .faiss
            )
        )
    }

    func testNonMatcherCrashDoesNotSelectExactRecovery() {
        let error = ColmapRunnerError.failed(
            command: "feature_extractor",
            exitCode: 10,
            terminationReason: .uncaughtSignal,
            stdoutTail: "",
            stderrTail: "segmentation fault"
        )

        XCTAssertNil(
            DescriptorMatcherRecoveryPolicy.reason(
                for: error,
                currentMatcher: .faiss
            )
        )
    }

    func testExactMatcherFailureCannotRetryExact() {
        let error = ColmapRunnerError.failed(
            command: "matches_importer",
            exitCode: 10,
            terminationReason: .uncaughtSignal,
            stdoutTail: "",
            stderrTail: "segmentation fault"
        )

        XCTAssertNil(
            DescriptorMatcherRecoveryPolicy.reason(
                for: error,
                currentMatcher: .exact
            )
        )
    }

    func testGeometryRejectionSelectsExactOnlyAfterFaissRetries() {
        XCTAssertNil(
            DescriptorMatcherRecoveryPolicy.reasonForRejectedGeometry(
                currentMatcher: .faiss,
                exhaustedFaissRetries: false
            )
        )
        XCTAssertEqual(
            DescriptorMatcherRecoveryPolicy.reasonForRejectedGeometry(
                currentMatcher: .faiss,
                exhaustedFaissRetries: true
            ),
            .faissGeometryRejectedAfterRetries
        )
        XCTAssertNil(
            DescriptorMatcherRecoveryPolicy.reasonForRejectedGeometry(
                currentMatcher: .exact,
                exhaustedFaissRetries: true
            )
        )
    }

    func testDa3ExactTransitionIsReportedEvenWhenExactAttemptAlsoFails() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try writeEmptyMatchTables(at: paths.colmapDatabaseURL)
        let pairList = root.appendingPathComponent("pairs.txt")
        try "a.jpg b.jpg\n".write(to: pairList, atomically: true, encoding: .utf8)

        let toolchain = TestToolchains.toolchainPaths(root: root)
        let subprocess = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(
                    exitCode: SIGSEGV,
                    terminationReason: .uncaughtSignal,
                    stdout: "",
                    stderr: "segmentation fault"
                )
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(
                    exitCode: 1,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: "exact matcher failed"
                )
            ),
        ])
        let runner = PipelineRunner(
            projectURL: root,
            config: .init(toolchain: toolchain),
            tooling: .init(runner: subprocess)
        )
        var didSelectExactRecovery = false

        do {
            try await runner.test_runDa3MatchesImporterWithOneShotExactRecovery(
                database: paths.colmapDatabaseURL,
                matchListPath: pairList,
                options: ColmapOptions(
                    useGPU: false,
                    extractThreads: 1,
                    matchThreads: 1
                ),
                onExactRecovery: { didSelectExactRecovery = true }
            )
            XCTFail("Expected the exact retry to fail")
        } catch {
            XCTAssertTrue(didSelectExactRecovery)
        }
    }

    private func writeEmptyMatchTables(at url: URL) throws {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            return XCTFail("Could not create matcher database")
        }
        XCTAssertEqual(
            sqlite3_exec(
                database,
                "CREATE TABLE matches(pair_id INTEGER PRIMARY KEY); CREATE TABLE two_view_geometries(pair_id INTEGER PRIMARY KEY);",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
    }
}
#endif
