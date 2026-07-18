import Darwin
import XCTest
@testable import EasySplatCore

final class SubprocessRunnerAsyncTests: XCTestCase {
    private enum TerminationCallbackError: Error, Equatable {
        case couldNotPersist
    }

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

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = false

        var value: Bool { lock.withLock { storage } }
        func set() { lock.withLock { storage = true } }
    }

    private final class LockedResults: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [SubprocessResult] = []

        var values: [SubprocessResult] { lock.withLock { storage } }

        func append(_ result: SubprocessResult) {
            lock.withLock { storage.append(result) }
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

    func testRunAsyncLaunchesRootInIsolatedProcessGroup() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = root.appendingPathComponent("report-process-group.sh")
        try TestFileBuilder.createExecutable(
            at: scriptURL,
            script: """
            #!/bin/sh
            pgid=$(/bin/ps -o pgid= -p $$ | /usr/bin/tr -d ' ')
            printf '%s %s\n' "$$" "$pgid"
            """
        )

        let result = try await SubprocessRunner().runAsync(scriptURL.path, [])
        let fields = result.stdout.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }

        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(fields.first, fields.last, "Foundation must isolate the child before exec")
        XCTAssertNotEqual(fields.last, getpgrp(), "Cancellation must never target the app process group")
    }

    func testRunAsyncReportsTerminationBeforeRethrowingCancellation() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = root.appendingPathComponent("cancel-with-receipt.sh")
        try TestFileBuilder.createExecutable(
            at: scriptURL,
            script: """
            #!/bin/sh
            trap 'exit 23' INT TERM
            printf 'ready\\n'
            while :; do :; done
            """
        )
        let ready = DispatchSemaphore(value: 0)
        let results = LockedResults()
        let runner = SubprocessRunner()

        let task = Task {
            try await runner.runAsync(
                scriptURL.path,
                [],
                currentDirectory: nil,
                environment: ["EASYSPLAT_SUBPROCESS_CUSTOM": "child"],
                removingEnvironmentKeys: ["EASYSPLAT_SUBPROCESS_CUSTOM"],
                onTermination: { results.append($0) },
                onStdout: { line in
                    if line == "ready" { ready.signal() }
                },
                onStderr: { _ in }
            )
        }

        let didStart = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: ready.wait(timeout: .now() + 2) == .success)
            }
        }
        guard didStart else {
            task.cancel()
            _ = try? await task.value
            return XCTFail("Child process did not start")
        }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected after the actual process termination has been observed.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let result = try XCTUnwrap(results.values.first)
        XCTAssertEqual(results.values.count, 1)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertEqual(
            result.environmentReceipt,
            SubprocessEnvironmentReceipt(
                explicitOverrides: ["EASYSPLAT_SUBPROCESS_CUSTOM": "child"],
                removedKeys: ["EASYSPLAT_SUBPROCESS_CUSTOM"],
                effectiveValuesForControlledKeys: ["EASYSPLAT_SUBPROCESS_CUSTOM": "child"]
            )
        )
    }

    func testRunAsyncPreservesTerminationCallbackFailureDuringCancellation() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = root.appendingPathComponent("cancel-with-failed-callback.sh")
        try TestFileBuilder.createExecutable(
            at: scriptURL,
            script: """
            #!/bin/sh
            trap 'exit 24' INT TERM
            printf 'ready\\n'
            while :; do :; done
            """
        )
        let ready = DispatchSemaphore(value: 0)
        let results = LockedResults()

        let task = Task {
            try await SubprocessRunner().runAsync(
                scriptURL.path,
                [],
                currentDirectory: nil,
                environment: [:],
                removingEnvironmentKeys: [],
                onTermination: { result in
                    results.append(result)
                    throw TerminationCallbackError.couldNotPersist
                },
                onStdout: { line in
                    if line == "ready" { ready.signal() }
                },
                onStderr: { _ in }
            )
        }

        let didStart = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: ready.wait(timeout: .now() + 2) == .success)
            }
        }
        guard didStart else {
            task.cancel()
            _ = try? await task.value
            return XCTFail("Child process did not start")
        }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected the durable-recording failure")
        } catch let error as TerminationCallbackError {
            XCTAssertEqual(error, .couldNotPersist)
        } catch {
            XCTFail("Expected callback failure, got \(error)")
        }
        XCTAssertEqual(results.values.count, 1)
    }

    func testRunAsyncDoesNotReportTerminationWhenLaunchFails() async throws {
        let results = LockedResults()
        let missingExecutable = "/tmp/easysplat-missing-\(UUID().uuidString)"

        do {
            _ = try await SubprocessRunner().runAsync(
                missingExecutable,
                [],
                currentDirectory: nil,
                environment: [:],
                removingEnvironmentKeys: [],
                onTermination: { results.append($0) },
                onStdout: { _ in },
                onStderr: { _ in }
            )
            XCTFail("Expected launch failure")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertTrue(results.values.isEmpty)
    }

    func testRunAsyncDoesNotLaunchWhenTaskWasAlreadyCancelled() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinelURL = root.appendingPathComponent("must-not-exist")
        let scriptURL = root.appendingPathComponent("pre-cancelled.sh")
        try TestFileBuilder.createExecutable(
            at: scriptURL,
            script: "#!/bin/sh\n/usr/bin/touch \"$1\"\n"
        )
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let results = LockedResults()

        let task = Task {
            entered.signal()
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    release.wait()
                    continuation.resume()
                }
            }
            return try await SubprocessRunner().runAsync(
                scriptURL.path,
                [sentinelURL.path],
                currentDirectory: nil,
                environment: [:],
                removingEnvironmentKeys: [],
                onTermination: { results.append($0) },
                onStdout: { _ in },
                onStderr: { _ in }
            )
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        task.cancel()
        release.signal()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected without crossing the process boundary.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinelURL.path))
        XCTAssertTrue(results.values.isEmpty)
    }

    func testRunAsyncCancellationTerminatesDescendantHoldingOutputPipes() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let descendantPIDURL = root.appendingPathComponent("descendant.pid")
        let scriptURL = root.appendingPathComponent("descendant-holds-pipes.sh")
        try TestFileBuilder.createExecutable(
            at: scriptURL,
            script: """
            #!/bin/sh
            (
                trap '' INT TERM
                /bin/sleep 8
            ) &
            descendant=$!
            printf '%s\n' "$descendant" > "$1"
            printf 'ready\n'
            trap 'exit 23' INT TERM
            while :; do :; done
            """
        )
        let ready = DispatchSemaphore(value: 0)
        let results = LockedResults()

        let task = Task {
            try await SubprocessRunner().runAsync(
                scriptURL.path,
                [descendantPIDURL.path],
                currentDirectory: nil,
                environment: [:],
                removingEnvironmentKeys: [],
                onTermination: { results.append($0) },
                onStdout: { line in
                    if line == "ready" { ready.signal() }
                },
                onStderr: { _ in }
            )
        }
        let didStart = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: ready.wait(timeout: .now() + 2) == .success)
            }
        }
        guard didStart else {
            task.cancel()
            _ = try? await task.value
            return XCTFail("Child process did not start")
        }
        let descendantPID = try XCTUnwrap(
            Int32(try String(contentsOf: descendantPIDURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )

        let clock = ContinuousClock()
        let started = clock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected after root and descendant termination are observed.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let elapsed = started.duration(to: clock.now)

        XCTAssertLessThan(elapsed, .seconds(3))
        XCTAssertEqual(results.values.count, 1)
        let descendantRemainsAlive = await processRemainsAlive(descendantPID)
        XCTAssertFalse(descendantRemainsAlive)
    }

    func testRunAsyncLateCancellationUnblocksDrainAfterRootExited() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let processPIDsURL = root.appendingPathComponent("late-cancel-processes.pid")
        let scriptURL = root.appendingPathComponent("root-exits-before-cancel.sh")
        try TestFileBuilder.createExecutable(
            at: scriptURL,
            script: """
            #!/bin/sh
            (
                trap '' INT TERM HUP
                exec /bin/sleep 60
            ) &
            descendant=$!
            printf '%s %s\n' "$$" "$descendant" > "$1"
            printf 'root-exited\n'
            exit 0
            """
        )
        let results = LockedResults()

        let task = Task {
            try await SubprocessRunner().runAsync(
                scriptURL.path,
                [processPIDsURL.path],
                currentDirectory: nil,
                environment: [:],
                removingEnvironmentKeys: [],
                onTermination: { results.append($0) },
                onStdout: { _ in },
                onStderr: { _ in }
            )
        }
        let processPIDs = try await waitForPIDs(in: processPIDsURL, count: 2, timeout: 5)
        let rootPID = processPIDs[0]
        let descendantPID = processPIDs[1]
        defer {
            _ = kill(rootPID, SIGKILL)
            _ = kill(descendantPID, SIGKILL)
        }
        guard await waitForProcessExit(rootPID, timeout: 5) else {
            task.cancel()
            _ = try? await task.value
            return XCTFail("Root process did not exit")
        }

        // Give Foundation's termination handler time to enter its EOF drain while
        // the inherited write ends remain open in the background descendant.
        try await Task.sleep(nanoseconds: 200_000_000)
        let finished = DispatchSemaphore(value: 0)
        Task {
            _ = try? await task.value
            finished.signal()
        }
        XCTAssertEqual(finished.wait(timeout: .now()), .timedOut)

        let clock = ContinuousClock()
        let started = clock.now
        task.cancel()
        let finishedBeforeCleanup = await wait(for: finished, timeout: 2)
        let elapsed = started.duration(to: clock.now)
        if !finishedBeforeCleanup {
            _ = kill(descendantPID, SIGKILL)
            _ = await wait(for: finished, timeout: 2)
        }

        XCTAssertTrue(finishedBeforeCleanup, "Late cancellation remained blocked in pipe finalization")
        XCTAssertLessThan(elapsed, .seconds(3))
        XCTAssertEqual(results.values.count, 1)
        XCTAssertTrue(results.values[0].stdout.contains("root-exited"))
        let descendantRemainsAlive = await processRemainsAlive(descendantPID)
        XCTAssertFalse(descendantRemainsAlive)
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected after termination reporting and pipe finalization.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testRunAsyncCancellationTerminatesDescendantForkedBySIGINTHandler() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let lateDescendantPIDURL = root.appendingPathComponent("sigint-descendant.pid")
        let scriptURL = root.appendingPathComponent("fork-on-sigint.sh")
        try TestFileBuilder.createExecutable(
            at: scriptURL,
            script: """
            #!/bin/sh
            pid_file=$1
            handle_int() {
                (
                    trap '' INT TERM HUP
                    exec /bin/sleep 60
                ) &
                descendant=$!
                printf '%s\n' "$descendant" > "$pid_file"
                exit 23
            }
            trap handle_int INT
            printf 'ready\n'
            while :; do :; done
            """
        )
        let ready = DispatchSemaphore(value: 0)
        let results = LockedResults()

        let task = Task {
            try await SubprocessRunner().runAsync(
                scriptURL.path,
                [lateDescendantPIDURL.path],
                currentDirectory: nil,
                environment: [:],
                removingEnvironmentKeys: [],
                onTermination: { results.append($0) },
                onStdout: { line in
                    if line == "ready" { ready.signal() }
                },
                onStderr: { _ in }
            )
        }
        guard await wait(for: ready, timeout: 5) else {
            task.cancel()
            _ = try? await task.value
            return XCTFail("Root process did not start")
        }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected after termination reporting and descendant cleanup.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let lateDescendantPID = try await waitForPID(in: lateDescendantPIDURL, timeout: 5)
        defer { _ = kill(lateDescendantPID, SIGKILL) }
        XCTAssertEqual(results.values.count, 1)
        let descendantRemainsAlive = await processRemainsAlive(lateDescendantPID)
        XCTAssertFalse(descendantRemainsAlive)
    }

    func testRunAsyncCancellationDuringTerminationCallbackWaitsForCleanup() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let descendantPIDURL = root.appendingPathComponent("callback-race-descendant.pid")
        let scriptURL = root.appendingPathComponent("exit-with-detached-descendant.sh")
        try TestFileBuilder.createExecutable(
            at: scriptURL,
            script: """
            #!/bin/sh
            (
                trap '' INT TERM HUP
                exec /bin/sleep 60
            ) </dev/null >/dev/null 2>&1 &
            descendant=$!
            printf '%s\n' "$descendant" > "$1"
            exit 0
            """
        )
        let callbackEntered = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)

        let task = Task {
            try await SubprocessRunner().runAsync(
                scriptURL.path,
                [descendantPIDURL.path],
                currentDirectory: nil,
                environment: [:],
                removingEnvironmentKeys: [],
                onTermination: { _ in
                    callbackEntered.signal()
                    releaseCallback.wait()
                },
                onStdout: { _ in },
                onStderr: { _ in }
            )
        }
        guard await wait(for: callbackEntered, timeout: 5) else {
            task.cancel()
            releaseCallback.signal()
            _ = try? await task.value
            return XCTFail("Termination callback did not start")
        }
        let descendantPID = try XCTUnwrap(
            Int32(try String(contentsOf: descendantPIDURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines))
        )
        defer { _ = kill(descendantPID, SIGKILL) }

        task.cancel()
        releaseCallback.signal()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected only after the cancellation cleanup is complete.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        XCTAssertFalse(isProcessAlive(descendantPID), "Cancellation returned before descendant cleanup")
    }

    func testRunAsyncWaitsForOrderedStreamingCallbacksBeforeReturning() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = root.appendingPathComponent("ordered-callbacks.sh")
        try TestFileBuilder.createExecutable(
            at: scriptURL,
            script: """
            #!/bin/sh
            printf 'first\\n'
            /bin/sleep 0.05
            printf 'second\\n'
            """
        )
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let lines = LockedLines()
        let finished = LockedFlag()
        let runner = SubprocessRunner()

        let task = Task {
            let result = try await runner.runAsync(
                scriptURL.path,
                [],
                onStdout: { line in
                    if line == "first" {
                        entered.signal()
                        release.wait()
                    }
                    lines.append(line)
                }
            )
            finished.set()
            return result
        }

        let didEnter = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(
                    returning: entered.wait(timeout: .now() + 2) == .success
                )
            }
        }
        guard didEnter else {
            release.signal()
            _ = try? await task.value
            return XCTFail("First streaming callback did not arrive")
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(finished.value)
        release.signal()

        let result = try await task.value
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(lines.value(), ["first", "second"])
        XCTAssertTrue(finished.value)
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

    func testRunRemovesExplicitInheritedEnvironmentKeysBeforeApplyingOverrides() throws {
        let sentinelKey = makeSentinelKey()
        RuntimeEnvironment.setValue("parent", forKey: sentinelKey)
        defer { RuntimeEnvironment.setValue(nil, forKey: sentinelKey) }
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = try makeEnvironmentScript(
            in: root,
            name: "env-filter-sync.sh",
            sentinelKey: sentinelKey
        )

        let result = try SubprocessRunner().run(
            scriptURL.path,
            [],
            currentDirectory: nil,
            environment: ["EASYSPLAT_SUBPROCESS_CUSTOM": "child"],
            removingEnvironmentKeys: [sentinelKey, "EASYSPLAT_SUBPROCESS_CUSTOM"],
            onStdout: { _ in },
            onStderr: { _ in }
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("sentinel=\n"))
        XCTAssertTrue(result.stdout.contains("custom=child"))
        XCTAssertEqual(
            result.environmentReceipt,
            SubprocessEnvironmentReceipt(
                explicitOverrides: ["EASYSPLAT_SUBPROCESS_CUSTOM": "child"],
                removedKeys: [sentinelKey, "EASYSPLAT_SUBPROCESS_CUSTOM"],
                effectiveValuesForControlledKeys: [
                    "EASYSPLAT_SUBPROCESS_CUSTOM": "child"
                ]
            )
        )
    }

    func testRunAsyncRemovesExplicitInheritedEnvironmentKeysBeforeApplyingOverrides() async throws {
        let sentinelKey = makeSentinelKey()
        RuntimeEnvironment.setValue("parent", forKey: sentinelKey)
        defer { RuntimeEnvironment.setValue(nil, forKey: sentinelKey) }
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let scriptURL = try makeEnvironmentScript(
            in: root,
            name: "env-filter-async.sh",
            sentinelKey: sentinelKey
        )

        let result = try await SubprocessRunner().runAsync(
            scriptURL.path,
            [],
            currentDirectory: nil,
            environment: ["EASYSPLAT_SUBPROCESS_CUSTOM": "child"],
            removingEnvironmentKeys: [sentinelKey, "EASYSPLAT_SUBPROCESS_CUSTOM"],
            onStdout: { _ in },
            onStderr: { _ in }
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.stdout.contains("sentinel=\n"))
        XCTAssertTrue(result.stdout.contains("custom=child"))
        XCTAssertEqual(
            result.environmentReceipt,
            SubprocessEnvironmentReceipt(
                explicitOverrides: ["EASYSPLAT_SUBPROCESS_CUSTOM": "child"],
                removedKeys: [sentinelKey, "EASYSPLAT_SUBPROCESS_CUSTOM"],
                effectiveValuesForControlledKeys: [
                    "EASYSPLAT_SUBPROCESS_CUSTOM": "child"
                ]
            )
        )
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

    private func processRemainsAlive(_ pid: pid_t) async -> Bool {
        for _ in 0..<20 {
            if kill(pid, 0) != 0, errno == ESRCH {
                return false
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return kill(pid, 0) == 0 || errno != ESRCH
    }

    private func isProcessAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    private func wait(for semaphore: DispatchSemaphore, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + timeout) == .success)
            }
        }
    }

    private func waitForPID(in url: URL, timeout: TimeInterval) async throws -> pid_t {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let contents = try? String(contentsOf: url, encoding: .utf8),
               let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return pid
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Timed out waiting for descendant PID at \(url.path)")
        throw CocoaError(.fileReadNoSuchFile)
    }

    private func waitForPIDs(in url: URL, count: Int, timeout: TimeInterval) async throws -> [pid_t] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let contents = try? String(contentsOf: url, encoding: .utf8) {
                let pids = contents.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }
                if pids.count == count { return pids }
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Timed out waiting for \(count) process IDs at \(url.path)")
        throw CocoaError(.fileReadNoSuchFile)
    }

    private func waitForProcessExit(_ pid: pid_t, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isProcessAlive(pid) { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return !isProcessAlive(pid)
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
