import XCTest
@testable import EasySplatCore

final class SubprocessRunnerAsyncTests: XCTestCase {
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

    func testRunHandlesInstantExit() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = root.appendingPathComponent("instant-sync.sh")
        try TestFileBuilder.createExecutable(at: scriptURL, script: "#!/usr/bin/env bash\nprintf sync-done\n")
        let runner = SubprocessRunner()

        let result = try runner.run(scriptURL.path, [])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "sync-done")
    }

    func testRunAsyncHandlesInstantExit() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = root.appendingPathComponent("instant.sh")
        try TestFileBuilder.createExecutable(at: scriptURL, script: "#!/usr/bin/env bash\nprintf done\n")
        let runner = SubprocessRunner()

        let result = try await runner.runAsync(scriptURL.path, [])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "done")
    }

    func testRunMergesEnvironmentOverridesWithInheritedEnvironment() async throws {
        let sentinelKey = makeSentinelKey()
        RuntimeEnvironment.setValue("parent", forKey: sentinelKey)
        defer { RuntimeEnvironment.setValue(nil, forKey: sentinelKey) }
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = try makeEnvironmentScript(in: root, name: "env-sync.sh", sentinelKey: sentinelKey)
        let runner = SubprocessRunner()

        let result = try runner.run(
            scriptURL.path,
            [],
            currentDirectory: nil,
            environment: ["EASYSPLAT_SUBPROCESS_CUSTOM": "child"],
            onStdout: { _ in },
            onStderr: { _ in }
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("sentinel=parent"))
        XCTAssertTrue(result.stdout.contains("custom=child"))
    }

    func testRunAsyncMergesEnvironmentOverridesWithInheritedEnvironment() async throws {
        let sentinelKey = makeSentinelKey()
        RuntimeEnvironment.setValue("parent", forKey: sentinelKey)
        defer { RuntimeEnvironment.setValue(nil, forKey: sentinelKey) }
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = try makeEnvironmentScript(in: root, name: "env-async.sh", sentinelKey: sentinelKey)
        let runner = SubprocessRunner()

        let result = try await runner.runAsync(
            scriptURL.path,
            [],
            currentDirectory: nil,
            environment: ["EASYSPLAT_SUBPROCESS_CUSTOM": "child"],
            onStdout: { _ in },
            onStderr: { _ in }
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("sentinel=parent"))
        XCTAssertTrue(result.stdout.contains("custom=child"))
    }

    func testRunAsyncPseudoTTYHandlesInstantExit() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = root.appendingPathComponent("instant-pty.sh")
        try TestFileBuilder.createExecutable(
            at: scriptURL,
            script: "#!/usr/bin/env bash\nprintf pty-stdout\nprintf pty-stderr >&2\n"
        )
        let runner = SubprocessRunner()

        let result = try await runner.runAsyncPseudoTTY(scriptURL.path, [])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "pty-stdout")
        XCTAssertEqual(result.stderr, "pty-stderr")
    }

    func testRunAsyncBoundsCapturedOutputButStreamsAllLines() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = root.appendingPathComponent("large-output.sh")
        try TestFileBuilder.createExecutable(
            at: scriptURL,
            script: """
            #!/usr/bin/env bash
            /usr/bin/perl -e 'binmode STDOUT; print "a" x 1200000, "\\n"'
            """
        )
        let lines = LockedLines()
        let runner = SubprocessRunner()

        let result = try await runner.runAsync(
            scriptURL.path,
            [],
            onStdout: { lines.append($0) }
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertLessThanOrEqual(result.stdout.utf8.count, 1_048_576)
        XCTAssertEqual(lines.value().first?.count, 1_200_000)
    }

    func testRunAsyncOutputBufferKeepsLargestValidMultibyteSuffix() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = root.appendingPathComponent("large-multibyte-output.sh")
        try TestFileBuilder.createExecutable(
            at: scriptURL,
            script: """
            #!/usr/bin/env bash
            /usr/bin/perl -e 'binmode STDOUT; print "\\xF0\\x9F\\x98\\x80" x 262145'
            """
        )
        let runner = SubprocessRunner()

        let result = try await runner.runAsync(scriptURL.path, [])

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, String(repeating: "\u{1F600}", count: 262144))
        XCTAssertLessThanOrEqual(result.stdout.utf8.count, 1_048_576)
    }

    private func makeSentinelKey() -> String {
        "EASYSPLAT_SUBPROCESS_SENTINEL_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
    }

    private func makeEnvironmentScript(in root: URL, name: String, sentinelKey: String) throws -> URL {
        let scriptURL = root.appendingPathComponent(name)
        try TestFileBuilder.createExecutable(
            at: scriptURL,
            script: """
            #!/bin/sh
            printf 'sentinel=%s\\n' "$\(sentinelKey)"
            printf 'custom=%s\\n' "$EASYSPLAT_SUBPROCESS_CUSTOM"
            """
        )
        return scriptURL
    }
}
