import XCTest
@testable import EasySplatCore

final class SubprocessRunnerPseudoTTYTests: XCTestCase {
    private final class LockedLines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func append(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }

        func value() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return lines
        }
    }

    func testPseudoTTYEmitsProgressUpdates() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = try makeProgressScript(in: root)
        let runner = SubprocessRunner()

        let stderrLines = try await runScript(runner: runner, scriptURL: scriptURL, usePseudoTTY: true)

        XCTAssertFalse(stderrLines.contains(where: { $0.contains("notty") }))
        XCTAssertTrue(stderrLines.contains(where: { $0.contains("progress 1/5") }))
        XCTAssertTrue(stderrLines.contains(where: { $0.contains("progress 5/5") }))
    }

    func testPipesDoNotExposeTtyProgress() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = try makeProgressScript(in: root)
        let runner = SubprocessRunner()

        let stderrLines = try await runScript(runner: runner, scriptURL: scriptURL, usePseudoTTY: false)

        XCTAssertTrue(stderrLines.contains(where: { $0.contains("notty") }))
        XCTAssertFalse(stderrLines.contains(where: { $0.contains("progress 1/5") }))
    }

    func testLaunchFailureStillAllowsSubsequentRuns() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = try makeProgressScript(in: root)
        let runner = SubprocessRunner()

        await XCTAssertThrowsErrorAsync {
            try await runner.runAsync("/path/that/does/not/exist", [])
        }

        let stderrLines = try await runScript(runner: runner, scriptURL: scriptURL, usePseudoTTY: false)
        XCTAssertTrue(stderrLines.contains(where: { $0.contains("notty") }))
    }

    private func makeProgressScript(in root: URL) throws -> URL {
        let scriptURL = root.appendingPathComponent("progress.sh")
        let script = """
        #!/usr/bin/env bash
        if [ -t 2 ]; then
          for i in 1 2 3 4 5; do
            printf "progress %d/5\\r" "$i" >&2
            sleep 0.02
          done
          printf "\\n" >&2
        else
          echo "notty" >&2
        fi
        """
        try TestFileBuilder.createExecutable(at: scriptURL, script: script)
        return scriptURL
    }

    private func runScript(
        runner: SubprocessRunner,
        scriptURL: URL,
        usePseudoTTY: Bool
    ) async throws -> [String] {
        let stderrLines = LockedLines()
        let capture: @Sendable (String) -> Void = { line in
            stderrLines.append(line)
        }
        if usePseudoTTY {
            _ = try await runner.runAsyncPseudoTTY(
                scriptURL.path,
                [],
                currentDirectory: nil,
                environment: [:],
                onStdout: { _ in },
                onStderr: { capture($0) }
            )
        } else {
            _ = try await runner.runAsync(
                scriptURL.path,
                [],
                currentDirectory: nil,
                environment: [:],
                onStdout: { _ in },
                onStderr: { capture($0) }
            )
        }
        return stderrLines.value()
    }
}
