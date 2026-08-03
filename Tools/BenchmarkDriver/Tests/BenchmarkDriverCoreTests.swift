import Foundation
import ImageIO
import Metal
import XCTest
@testable import EasySplatBenchmarkDriverCore

private final class HostSnapshotFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var lowPowerMode = false
    private var tick: UInt64 = 1

    func setLowPowerMode(_ enabled: Bool) {
        lock.lock()
        lowPowerMode = enabled
        lock.unlock()
    }

    func capture() -> HostStateSnapshot {
        lock.lock()
        defer { lock.unlock() }
        tick += 1
        return HostStateSnapshot(
            cpuTicks: .init(user: tick, system: tick, idle: tick * 10, nice: 0),
            vmPageouts: 0,
            vmSwapouts: 0,
            thermalState: .nominal,
            lowPowerMode: lowPowerMode,
            powerSource: .acPower
        )
    }
}

private final class MonitorResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<HostStateMonitorReceipt, Error>?

    func store(_ result: Result<HostStateMonitorReceipt, Error>) {
        lock.lock()
        value = result
        lock.unlock()
    }

    func result() -> Result<HostStateMonitorReceipt, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private func makeTestPowerSourceRunLoopSource() -> CFRunLoopSource? {
    var context = CFRunLoopSourceContext(
        version: 0,
        info: nil,
        retain: nil,
        release: nil,
        copyDescription: nil,
        equal: nil,
        hash: nil,
        schedule: nil,
        cancel: nil,
        perform: { _ in }
    )
    return CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
}

final class BenchmarkDriverCoreTests: XCTestCase {
    func testRenderCameraDigestMatchesSharedFloat32Vector() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureURL = repositoryRoot
            .appendingPathComponent("scripts/benchmark/fixtures/render-camera-digest-v1.json")
        let data = try Data(contentsOf: fixtureURL)
        let fixture = try JSONDecoder().decode(RenderCameraDigestFixture.self, from: data)
        XCTAssertEqual(fixture.schemaVersion, 1)
        XCTAssertEqual(try fixture.camera.stableDigest(), fixture.digest)
    }

    func testRenderCameraDigestNormalizesSignedAndUnderflowedZero() throws {
        var positive = RenderCamera(
            width: 64,
            height: 64,
            projectionMatrixColumnMajor: Array(repeating: 0, count: 16),
            worldToCameraMatrixColumnMajor: Array(repeating: 0, count: 16)
        )
        var negative = positive
        negative.projectionMatrixColumnMajor[1] = -0.0
        XCTAssertEqual(try positive.stableDigest(), try negative.stableDigest())
        positive.projectionMatrixColumnMajor[3] = 1
        XCTAssertNotEqual(try positive.stableDigest(), try negative.stableDigest())
    }

    func testHostStateSnapshotUsesStablePublicSchema() throws {
        let snapshot = try HostStateSnapshot.capture()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            [
                "cpu_ticks",
                "vm_pageouts",
                "vm_swapouts",
                "thermal_state",
                "low_power_mode",
                "power_source",
            ]
        )
        let ticks = try XCTUnwrap(object["cpu_ticks"] as? [String: NSNumber])
        XCTAssertEqual(Set(ticks.keys), ["user", "system", "idle", "nice"])
        XCTAssertGreaterThan(ticks.values.reduce(UInt64(0)) { $0 + $1.uint64Value }, 0)
        XCTAssertTrue(
            ["nominal", "fair", "serious", "critical"].contains(
                try XCTUnwrap(object["thermal_state"] as? String)
            )
        )
        XCTAssertTrue(
            ["ac_power", "battery_power", "ups_power"].contains(
                try XCTUnwrap(object["power_source"] as? String)
            )
        )
        XCTAssertEqual(try JSONDecoder().decode(HostStateSnapshot.self, from: data), snapshot)
    }

    func testHostStateMonitorCapturesAStopBoundedReceipt() throws {
        var readyDescriptors = [Int32](repeating: 0, count: 2)
        var stopDescriptors = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(pipe(&readyDescriptors), 0)
        XCTAssertEqual(pipe(&stopDescriptors), 0)
        defer {
            readyDescriptors.forEach { close($0) }
            stopDescriptors.forEach { close($0) }
        }

        var stopByte: UInt8 = 1
        XCTAssertEqual(write(stopDescriptors[1], &stopByte, 1), 1)
        let receipt = try HostStateMonitor.captureForTesting(
            sampleIntervalSeconds: 0.05,
            readyFileDescriptor: readyDescriptors[1],
            stopFileDescriptor: stopDescriptors[0],
            notificationCenter: NotificationCenter(),
            snapshotProvider: HostSnapshotFixture().capture
        )

        var readyByte: UInt8 = 0
        XCTAssertEqual(read(readyDescriptors[0], &readyByte, 1), 1)
        XCTAssertEqual(readyByte, 1)
        XCTAssertEqual(receipt.schemaVersion, 1)
        XCTAssertEqual(receipt.monotonicClock, "mach_absolute_time")
        XCTAssertEqual(receipt.sampleIntervalSeconds, 0.05)
        XCTAssertEqual(receipt.samples.count, 2)
        XCTAssertTrue(receipt.events.isEmpty)
        XCTAssertLessThan(
            receipt.samples[0].monotonicSeconds,
            receipt.samples[1].monotonicSeconds
        )

        let data = try JSONEncoder().encode(receipt)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            [
                "schema_version",
                "monotonic_clock",
                "sample_interval_seconds",
                "samples",
                "events",
            ]
        )
    }

    func testHostStateMonitorRejectsAnUnsafeSamplingInterval() throws {
        XCTAssertThrowsError(
            try HostStateMonitor.capture(
                sampleIntervalSeconds: 0.01,
                readyFileDescriptor: -1,
                stopFileDescriptor: -1
            )
        )
    }

    func testHostStateMonitorPreservesEventWhenPowerStateRecoversBeforeSnapshot() throws {
        var readyDescriptors = [Int32](repeating: 0, count: 2)
        var stopDescriptors = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(pipe(&readyDescriptors), 0)
        XCTAssertEqual(pipe(&stopDescriptors), 0)
        defer {
            readyDescriptors.forEach { close($0) }
            stopDescriptors.forEach { close($0) }
        }

        let notificationCenter = NotificationCenter()
        let notificationQueue = OperationQueue()
        notificationQueue.name = "EasySplat host monitor transient test callbacks"
        notificationQueue.maxConcurrentOperationCount = 1
        notificationQueue.isSuspended = true
        let snapshots = HostSnapshotFixture()
        let resultBox = MonitorResultBox()
        let finished = DispatchSemaphore(value: 0)
        let readyWriteDescriptor = readyDescriptors[1]
        let stopReadDescriptor = stopDescriptors[0]
        DispatchQueue.global().async {
            resultBox.store(
                Result {
                    try HostStateMonitor.captureForTesting(
                        sampleIntervalSeconds: 0.05,
                        readyFileDescriptor: readyWriteDescriptor,
                        stopFileDescriptor: stopReadDescriptor,
                        notificationCenter: notificationCenter,
                        notificationQueue: notificationQueue,
                        snapshotProvider: snapshots.capture
                    )
                }
            )
            finished.signal()
        }

        var readyByte: UInt8 = 0
        XCTAssertEqual(read(readyDescriptors[0], &readyByte, 1), 1)
        XCTAssertEqual(readyByte, 1)
        snapshots.setLowPowerMode(true)
        notificationCenter.post(
            name: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
        snapshots.setLowPowerMode(false)
        notificationQueue.isSuspended = false
        notificationQueue.waitUntilAllOperationsAreFinished()
        var stopByte: UInt8 = 1
        XCTAssertEqual(write(stopDescriptors[1], &stopByte, 1), 1)
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)

        let receipt = try XCTUnwrap(resultBox.result()).get()
        XCTAssertGreaterThanOrEqual(receipt.samples.count, 3)
        XCTAssertFalse(receipt.samples.contains { $0.state.lowPowerMode })
        XCTAssertEqual(
            receipt.events.map(\.kind),
            [.lowPowerMode]
        )
        XCTAssertEqual(
            receipt.events.map(\.monotonicSeconds),
            receipt.events.map(\.monotonicSeconds).sorted()
        )
        XCTAssertLessThan(
            try XCTUnwrap(receipt.events.first).monotonicSeconds,
            try XCTUnwrap(receipt.samples.last).monotonicSeconds
        )
        XCTAssertEqual(
            receipt.samples.map(\.monotonicSeconds),
            receipt.samples.map(\.monotonicSeconds).sorted()
        )
        let data = try JSONEncoder().encode(receipt)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(Set(event.keys), ["kind", "monotonic_seconds"])
        XCTAssertEqual(event["kind"] as? String, "low_power_mode")
    }

    func testHostStateMonitorDrainsQueuedNotificationsBeforeReturningReceipt() throws {
        var readyDescriptors = [Int32](repeating: 0, count: 2)
        var stopDescriptors = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(pipe(&readyDescriptors), 0)
        XCTAssertEqual(pipe(&stopDescriptors), 0)
        defer {
            readyDescriptors.forEach { close($0) }
            stopDescriptors.forEach { close($0) }
        }

        let notificationCenter = NotificationCenter()
        let notificationQueue = OperationQueue()
        notificationQueue.name = "EasySplat host monitor test callbacks"
        notificationQueue.maxConcurrentOperationCount = 1
        notificationQueue.isSuspended = true
        let snapshots = HostSnapshotFixture()
        let resultBox = MonitorResultBox()
        let monitorFinished = DispatchSemaphore(value: 0)
        let notificationFinished = DispatchSemaphore(value: 0)
        let readyWriteDescriptor = readyDescriptors[1]
        let stopReadDescriptor = stopDescriptors[0]
        DispatchQueue.global().async {
            resultBox.store(
                Result {
                    try HostStateMonitor.captureForTesting(
                        sampleIntervalSeconds: 0.05,
                        readyFileDescriptor: readyWriteDescriptor,
                        stopFileDescriptor: stopReadDescriptor,
                        notificationCenter: notificationCenter,
                        notificationQueue: notificationQueue,
                        snapshotProvider: snapshots.capture
                    )
                }
            )
            monitorFinished.signal()
        }

        var readyByte: UInt8 = 0
        XCTAssertEqual(read(readyDescriptors[0], &readyByte, 1), 1)
        XCTAssertEqual(readyByte, 1)
        DispatchQueue.global().async {
            notificationCenter.post(
                name: ProcessInfo.thermalStateDidChangeNotification,
                object: nil
            )
            notificationFinished.signal()
        }
        let notificationWasQueued = expectation(description: "notification callback was queued")
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(2)
            while notificationQueue.operationCount == 0, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            notificationWasQueued.fulfill()
        }
        wait(for: [notificationWasQueued], timeout: 3)
        XCTAssertGreaterThan(notificationQueue.operationCount, 0)

        var stopByte: UInt8 = 1
        XCTAssertEqual(write(stopDescriptors[1], &stopByte, 1), 1)
        XCTAssertEqual(monitorFinished.wait(timeout: .now() + 0.1), .timedOut)

        notificationQueue.isSuspended = false
        XCTAssertEqual(notificationFinished.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(monitorFinished.wait(timeout: .now() + 3), .success)
        let receipt = try XCTUnwrap(resultBox.result()).get()
        XCTAssertEqual(receipt.events.map(\.kind), [.thermalState])
    }

    func testPowerSourceObserverCancelsTimedOutStartupAndWaitsForExit() throws {
        let startupEntered = DispatchSemaphore(value: 0)
        let releaseStartup = DispatchSemaphore(value: 0)
        let threadReachedExit = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            releaseStartup.signal()
        }

        XCTAssertThrowsError(
            try PowerSourceChangeObserver.startForTesting(
                startupTimeoutSeconds: 0.01,
                shutdownTimeoutSeconds: 1,
                sourceFactory: { _ in makeTestPowerSourceRunLoopSource() },
                beforeSourceCreation: {
                    startupEntered.signal()
                    releaseStartup.wait()
                },
                beforeThreadExit: {
                    threadReachedExit.signal()
                }
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("starting"))
        }
        XCTAssertEqual(startupEntered.wait(timeout: .now()), .success)
        XCTAssertEqual(threadReachedExit.wait(timeout: .now()), .success)
    }

    func testPowerSourceObserverSurfacesShutdownTimeoutAndCanFinishOnRetry() throws {
        let threadReachedExit = DispatchSemaphore(value: 0)
        let releaseThreadExit = DispatchSemaphore(value: 0)
        let observer = try PowerSourceChangeObserver.startForTesting(
            startupTimeoutSeconds: 1,
            shutdownTimeoutSeconds: 1,
            sourceFactory: { _ in makeTestPowerSourceRunLoopSource() },
            beforeThreadExit: {
                threadReachedExit.signal()
                releaseThreadExit.wait()
            }
        )

        XCTAssertThrowsError(try observer.stop(timeoutSeconds: 0.01)) { error in
            XCTAssertTrue(error.localizedDescription.contains("stopping"))
        }
        XCTAssertEqual(threadReachedExit.wait(timeout: .now()), .success)
        releaseThreadExit.signal()
        XCTAssertNoThrow(try observer.stop(timeoutSeconds: 1))
    }

    func testPowerSourceObserverRejectsUnavailableNotificationSource() throws {
        XCTAssertThrowsError(
            try PowerSourceChangeObserver.startForTesting(
                startupTimeoutSeconds: 1,
                shutdownTimeoutSeconds: 1,
                sourceFactory: { _ in nil }
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("could not observe"))
        }
    }

    func testHostStateMonitorRejectsAClosedStopDescriptor() throws {
        var readyDescriptors = [Int32](repeating: 0, count: 2)
        var stopDescriptors = [Int32](repeating: 0, count: 2)
        XCTAssertEqual(pipe(&readyDescriptors), 0)
        XCTAssertEqual(pipe(&stopDescriptors), 0)
        close(stopDescriptors[0])
        stopDescriptors[0] = -1
        defer {
            readyDescriptors.forEach { close($0) }
            stopDescriptors.filter { $0 >= 0 }.forEach { close($0) }
        }

        XCTAssertThrowsError(
            try HostStateMonitor.capture(
                sampleIntervalSeconds: 0.05,
                readyFileDescriptor: readyDescriptors[1],
                stopFileDescriptor: stopDescriptors[0]
            )
        )
    }

    func testValidationRejectsHeldOutViewInTrainingSelection() throws {
        var job = makeJob()
        job.trainingViewIndices.append(4)

        XCTAssertThrowsError(try job.validate()) { error in
            XCTAssertTrue(error.localizedDescription.contains("excluded from training"))
        }
    }

    func testValidationRejectsMisorderedViewsAndSources() throws {
        var misorderedViews = makeJob()
        misorderedViews.views.reverse()
        XCTAssertThrowsError(try misorderedViews.validate())

        var misorderedSources = makeJob()
        misorderedSources.views[0].sources.swapAt(0, 1)
        XCTAssertThrowsError(try misorderedSources.validate())
    }

    func testValidationRejectsMixedSourceRunAcrossHoldouts() throws {
        var job = makeJob()
        job.views[1].sources[2].runID = "different-candidate-run"

        XCTAssertThrowsError(try job.validate()) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("one immutable source"),
                error.localizedDescription
            )
        }
    }

    func testValidationRejectsMixedSourcePLYAcrossHoldouts() throws {
        var job = makeJob()
        job.views[1].sources[2].plySHA256 = digest("9")

        XCTAssertThrowsError(try job.validate()) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("one immutable source"),
                error.localizedDescription
            )
        }
    }

    func testValidationRejectsRenderTargetsAbovePixelBudget() throws {
        var job = makeJob()
        job.views[0].camera.width = 4_096
        job.views[0].camera.height = 2_048

        XCTAssertThrowsError(try job.validate()) { error in
            XCTAssertTrue(error.localizedDescription.contains("render camera"))
        }
    }

    func testRendererFailsWhenMetalIsUnavailable() {
        XCTAssertThrowsError(try MetalOffscreenRenderer(device: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Metal is unavailable"))
        }
    }

    func testSortFailureWakesImmediately() {
        let started = ContinuousClock.now

        XCTAssertThrowsError(
            try MetalOffscreenRenderer.awaitSort(timeout: .seconds(5)) { finish in
                finish(.failure("synthetic sort failure"))
            }
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("synthetic sort failure"))
        }
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }

    func testCheckoutSnapshotDetectsMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try runGit(["init", "--quiet"], at: root)
        try "fixture\n".write(
            to: root.appendingPathComponent("fixture.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "fixture.txt"], at: root)
        try runGit(
            [
                "-c", "user.name=EasySplat Tests",
                "-c", "user.email=tests@easysplat.invalid",
                "commit", "--quiet", "-m", "fixture",
            ],
            at: root
        )
        let snapshot = try CheckoutSnapshot.capture(root: root)

        try "changed\n".write(
            to: root.appendingPathComponent("fixture.txt"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(try snapshot.verifyUnchanged()) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed during rendering"))
        }
    }

    func testDriverWritesBoundManifestAndOneReceiptPerRender() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = try makeCheckout(at: root.appendingPathComponent("candidate"))
        let baseline = try makeCheckout(at: root.appendingPathComponent("baseline"))
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("benchmark-driver")
        try Data("renderer executable".utf8).write(to: executable)
        let groundTruth = artifacts.appendingPathComponent("ground-truth.png")
        try Data("ground truth".utf8).write(to: groundTruth)
        let groundTruthSource = artifacts.appendingPathComponent("ground-truth-source.png")
        try Data("ground truth source".utf8).write(to: groundTruthSource)
        let preparation = artifacts.appendingPathComponent("ground-truth-preparation.json")
        try Data("preparation".utf8).write(to: preparation)

        let sources = try RenderVariant.allCases.map { variant -> RenderSource in
            let sourcePath = "sources/\(variant.rawValue).ply"
            let sourceURL = artifacts.appendingPathComponent(sourcePath)
            try FileManager.default.createDirectory(
                at: sourceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("ply \(variant.rawValue)".utf8).write(to: sourceURL)
            return RenderSource(
                variant: variant,
                runID: "\(variant.rawValue)-run",
                checkoutCommit: variant == .pairedBaseline ? baseline.commit : candidate.commit,
                toolchainIdentity: digest("4"),
                sourceExecutableSHA256: digest("6"),
                plyPath: sourcePath,
                plySHA256: try MetalOffscreenRenderer.sha256(fileAt: sourceURL),
                outputPath: "rendering/\(variant.rawValue)/000001.png"
            )
        }
        let job = BenchmarkRenderJob(
            schemaVersion: 2,
            sceneID: "orbit-01",
            scale: 2,
            requestDigest: digest("0"),
            inputDigest: digest("2"),
            rendererClosureSHA256: digest("8"),
            rendererExecutableSHA256: try MetalOffscreenRenderer.sha256(fileAt: executable),
            groundTruthPreparation: GroundTruthPreparationBinding(
                path: "ground-truth-preparation.json",
                sha256: try MetalOffscreenRenderer.sha256(fileAt: preparation)
            ),
            holdoutIndices: [1],
            trainingViewIndices: [0],
            candidateCheckout: CheckoutBinding(path: candidate.root.path, commit: candidate.commit),
            baselineCheckout: CheckoutBinding(path: baseline.root.path, commit: baseline.commit),
            views: [
                RenderViewJob(
                    holdoutIndex: 1,
                    camera: RenderCamera(
                        width: 64,
                        height: 64,
                        projectionMatrixColumnMajor: identity,
                        worldToCameraMatrixColumnMajor: identity
                    ),
                    groundTruth: GroundTruthImage(
                        path: "ground-truth.png",
                        sha256: try MetalOffscreenRenderer.sha256(fileAt: groundTruth),
                        sourcePath: "ground-truth-source.png",
                        sourceSHA256: try MetalOffscreenRenderer.sha256(fileAt: groundTruthSource),
                        preparationViewSHA256: digest("9")
                    ),
                    sources: sources
                )
            ]
        )
        let driver = BenchmarkRenderDriver { source, _, output in
            try Data("rendered \(source.lastPathComponent)".utf8).write(to: output, options: .atomic)
            return try MetalOffscreenRenderer.sha256(fileAt: output)
        }
        let manifestURL = artifacts.appendingPathComponent("rendering-manifest.json")

        var substitutedJob = job
        substitutedJob.rendererExecutableSHA256 = digest("f")
        XCTAssertThrowsError(
            try driver.execute(
                job: substitutedJob,
                artifactRoot: artifacts,
                manifestURL: manifestURL,
                rendererExecutableURL: executable
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("approved"))
        }

        try driver.execute(
            job: job,
            artifactRoot: artifacts,
            manifestURL: manifestURL,
            rendererExecutableURL: executable
        )

        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        XCTAssertEqual(manifest["request_digest"] as? String, job.requestDigest)
        XCTAssertEqual(manifest["renderer_closure_sha256"] as? String,
                       job.rendererClosureSHA256)
        XCTAssertEqual(manifest["renderer_executable_sha256"] as? String,
                       try MetalOffscreenRenderer.sha256(fileAt: executable))
        XCTAssertEqual(manifest["schema_version"] as? Int, 2)
        XCTAssertEqual(
            manifest["ground_truth_preparation_sha256"] as? String,
            job.groundTruthPreparation.sha256
        )
        let operations = try XCTUnwrap(manifest["render_operations"] as? [[String: Any]])
        XCTAssertEqual(operations.count, RenderVariant.allCases.count)
        XCTAssertEqual(operations.map { $0["variant"] as? String }, RenderVariant.allCases.map(\.rawValue))
        XCTAssertTrue(operations.allSatisfy { $0["source_executable_sha256"] as? String == digest("6") })
        XCTAssertTrue(operations.allSatisfy { $0["argv"] == nil && $0["exit_code"] == nil })
        XCTAssertEqual(try CheckoutSnapshot.capture(root: candidate.root).commit, candidate.commit)
        XCTAssertEqual(try CheckoutSnapshot.capture(root: baseline.root).commit, baseline.commit)
    }

    func testDriverLoadsEachImmutableSourceOnceAndKeepsCanonicalEvidenceOrder() throws {
        let fixture = try makeDriverFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var loads = [String]()
        let driver = BenchmarkRenderDriver(loadScene: { source in
            loads.append(source.lastPathComponent)
            return StubLoadedScene { _, output in
                try Data("rendered \(source.lastPathComponent)".utf8).write(
                    to: output,
                    options: .atomic
                )
                return try MetalOffscreenRenderer.sha256(fileAt: output)
            }
        })
        let manifestURL = fixture.artifacts.appendingPathComponent("rendering-manifest.json")

        try driver.execute(
            job: fixture.job,
            artifactRoot: fixture.artifacts,
            manifestURL: manifestURL,
            rendererExecutableURL: fixture.executable
        )

        XCTAssertEqual(
            loads,
            RenderVariant.allCases.map { "\($0.rawValue).ply" }
        )
        let manifest = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        )
        let views = try XCTUnwrap(manifest["views"] as? [[String: Any]])
        XCTAssertEqual(views.compactMap { $0["holdout_index"] as? Int }, fixture.job.holdoutIndices)
        for view in views {
            let renders = try XCTUnwrap(view["renders"] as? [[String: Any]])
            XCTAssertEqual(
                renders.compactMap { $0["variant"] as? String },
                RenderVariant.allCases.map(\.rawValue)
            )
        }
        let operations = try XCTUnwrap(manifest["render_operations"] as? [[String: Any]])
        let expectedOperations = RenderVariant.allCases.flatMap { variant in
            fixture.job.holdoutIndices.map { "render-\(String(format: "%06d", $0))-\(variant.rawValue)" }
        }
        XCTAssertEqual(
            operations.compactMap { $0["operation_id"] as? String },
            expectedOperations
        )
    }

    func testDriverRejectsSnapshotMutationDuringSceneLoad() throws {
        let fixture = try makeDriverFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let driver = BenchmarkRenderDriver(loadScene: { source in
            try Data("tampered snapshot".utf8).write(to: source, options: .atomic)
            return StubLoadedScene { _, _ in self.digest("f") }
        })

        XCTAssertThrowsError(
            try driver.execute(
                job: fixture.job,
                artifactRoot: fixture.artifacts,
                manifestURL: fixture.artifacts.appendingPathComponent("rendering-manifest.json"),
                rendererExecutableURL: fixture.executable
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("snapshot changed"),
                error.localizedDescription
            )
        }
    }

    func testDriverRejectsGroundTruthMutationBeforeCompletion() throws {
        let fixture = try makeDriverFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let groundTruth = fixture.artifacts.appendingPathComponent(
            fixture.job.views[0].groundTruth.path
        )
        var mutated = false
        let driver = BenchmarkRenderDriver(loadScene: { source in
            StubLoadedScene { _, output in
                if !mutated {
                    mutated = true
                    try Data("changed ground truth".utf8).write(to: groundTruth, options: .atomic)
                }
                try Data("rendered \(source.lastPathComponent)".utf8).write(
                    to: output,
                    options: .atomic
                )
                return try MetalOffscreenRenderer.sha256(fileAt: output)
            }
        })

        XCTAssertThrowsError(
            try driver.execute(
                job: fixture.job,
                artifactRoot: fixture.artifacts,
                manifestURL: fixture.artifacts.appendingPathComponent("rendering-manifest.json"),
                rendererExecutableURL: fixture.executable
            )
        ) { error in
            let description = error.localizedDescription
            XCTAssertTrue(
                description.contains("ground-truth image") && description.contains("changed"),
                description
            )
        }
    }

    func testDriverRejectsPreparationInputMutationBeforeCompletion() throws {
        for kind in ["receipt", "source"] {
            let fixture = try makeDriverFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let protectedInput = fixture.artifacts.appendingPathComponent(
                kind == "receipt"
                    ? fixture.job.groundTruthPreparation.path
                    : fixture.job.views[0].groundTruth.sourcePath
            )
            var mutated = false
            let driver = BenchmarkRenderDriver(loadScene: { source in
                StubLoadedScene { _, output in
                    if !mutated {
                        mutated = true
                        try Data("changed \(kind)".utf8).write(
                            to: protectedInput,
                            options: .atomic
                        )
                    }
                    try Data("rendered \(source.lastPathComponent)".utf8).write(
                        to: output,
                        options: .atomic
                    )
                    return try MetalOffscreenRenderer.sha256(fileAt: output)
                }
            })

            XCTAssertThrowsError(
                try driver.execute(
                    job: fixture.job,
                    artifactRoot: fixture.artifacts,
                    manifestURL: fixture.artifacts.appendingPathComponent(
                        "rendering-manifest.json"
                    ),
                    rendererExecutableURL: fixture.executable
                )
            ) { error in
                XCTAssertTrue(
                    error.localizedDescription.contains("changed"),
                    error.localizedDescription
                )
            }
        }
    }

    func testProductionRendererProducesDeterministicRGBPNG() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this test host.")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ply = root.appendingPathComponent("fixture.ply")
        try minimalSplatPLY.write(to: ply, atomically: true, encoding: .utf8)
        let first = root.appendingPathComponent("first.png")
        let second = root.appendingPathComponent("second.png")
        let camera = RenderCamera(
            width: 64,
            height: 64,
            projectionMatrixColumnMajor: perspectiveProjection,
            worldToCameraMatrixColumnMajor: translatedView
        )
        let renderer = try MetalOffscreenRenderer(device: device)

        let firstSHA = try renderer.render(plyURL: ply, camera: camera, outputURL: first)
        let secondSHA = try renderer.render(plyURL: ply, camera: camera, outputURL: second)

        XCTAssertEqual(firstSHA, secondSHA)
        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(first as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 64)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 64)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let pixels = try XCTUnwrap(image.dataProvider?.data as Data?)
        XCTAssertTrue(pixels.contains { $0 != 0 }, "The production raster path must draw the fixture splat.")
    }

    func testJobRequiresSupervisorProvidedRequestAndRendererDigests() throws {
        let job = makeJob()
        var substituted = job
        substituted.requestDigest = "not-a-digest"
        XCTAssertThrowsError(try substituted.validate())

        substituted = job
        substituted.rendererClosureSHA256 = "not-a-digest"
        XCTAssertThrowsError(try substituted.validate())
    }

    func testDriverRejectsSymlinkedInputAncestorsBeforeReading() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = try makeCheckout(at: root.appendingPathComponent("candidate"))
        let baseline = try makeCheckout(at: root.appendingPathComponent("baseline"))
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("benchmark-driver")
        try Data("renderer executable".utf8).write(to: executable)
        let outsideGroundTruth = outside.appendingPathComponent("ground-truth.png")
        let outsideGroundTruthSource = outside.appendingPathComponent("ground-truth-source.png")
        let outsidePLY = outside.appendingPathComponent("source.ply")
        try Data("ground truth".utf8).write(to: outsideGroundTruth)
        try Data("ground truth source".utf8).write(to: outsideGroundTruthSource)
        try Data("ply source".utf8).write(to: outsidePLY)
        try FileManager.default.createSymbolicLink(
            at: artifacts.appendingPathComponent("linked"),
            withDestinationURL: outside
        )

        var job = makeJob()
        job.candidateCheckout = CheckoutBinding(path: candidate.root.path, commit: candidate.commit)
        job.baselineCheckout = CheckoutBinding(path: baseline.root.path, commit: baseline.commit)
        for viewIndex in job.views.indices {
            for sourceIndex in job.views[viewIndex].sources.indices {
                let variant = job.views[viewIndex].sources[sourceIndex].variant
                job.views[viewIndex].sources[sourceIndex].checkoutCommit =
                    variant == .pairedBaseline ? baseline.commit : candidate.commit
            }
        }
        job.rendererExecutableSHA256 = try MetalOffscreenRenderer.sha256(fileAt: executable)
        let preparation = artifacts.appendingPathComponent("ground-truth-preparation.json")
        try Data("preparation".utf8).write(to: preparation)
        job.groundTruthPreparation = GroundTruthPreparationBinding(
            path: "ground-truth-preparation.json",
            sha256: try MetalOffscreenRenderer.sha256(fileAt: preparation)
        )
        job.views[0].groundTruth = GroundTruthImage(
            path: "linked/ground-truth.png",
            sha256: try MetalOffscreenRenderer.sha256(fileAt: outsideGroundTruth),
            sourcePath: "linked/ground-truth-source.png",
            sourceSHA256: try MetalOffscreenRenderer.sha256(fileAt: outsideGroundTruthSource),
            preparationViewSHA256: digest("9")
        )
        var rendered = false
        let driver = BenchmarkRenderDriver { _, _, _ in
            rendered = true
            return self.digest("f")
        }

        XCTAssertThrowsError(
            try driver.execute(
                job: job,
                artifactRoot: artifacts,
                manifestURL: artifacts.appendingPathComponent("rendering-manifest.json"),
                rendererExecutableURL: executable
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("symbolic link"),
                error.localizedDescription
            )
        }
        XCTAssertFalse(rendered)

        for index in job.holdoutIndices {
            let groundTruth = artifacts.appendingPathComponent(
                "rendering/ground-truth/\(index).png"
            )
            try FileManager.default.createDirectory(
                at: groundTruth.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("ground truth \(index)".utf8).write(to: groundTruth)
            let groundTruthSource = artifacts.appendingPathComponent(
                "rendering/source/\(index).png"
            )
            try FileManager.default.createDirectory(
                at: groundTruthSource.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("ground truth source \(index)".utf8).write(to: groundTruthSource)
            let position = try XCTUnwrap(job.views.firstIndex { $0.holdoutIndex == index })
            job.views[position].groundTruth = GroundTruthImage(
                path: "rendering/ground-truth/\(index).png",
                sha256: try MetalOffscreenRenderer.sha256(fileAt: groundTruth),
                sourcePath: "rendering/source/\(index).png",
                sourceSHA256: try MetalOffscreenRenderer.sha256(fileAt: groundTruthSource),
                preparationViewSHA256: digest("9")
            )
        }
        for viewIndex in job.views.indices {
            job.views[viewIndex].sources[0].plyPath = "linked/source.ply"
            job.views[viewIndex].sources[0].plySHA256 =
                try MetalOffscreenRenderer.sha256(fileAt: outsidePLY)
        }

        XCTAssertThrowsError(
            try driver.execute(
                job: job,
                artifactRoot: artifacts,
                manifestURL: artifacts.appendingPathComponent("rendering-manifest.json"),
                rendererExecutableURL: executable
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("symbolic link"),
                error.localizedDescription
            )
        }
        XCTAssertFalse(rendered)
    }

    func testDriverRejectsSymlinkedArtifactRootAndExecutable() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let realArtifacts = parent.appendingPathComponent("artifacts", isDirectory: true)
        let linkedArtifacts = parent.appendingPathComponent("linked-artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: realArtifacts, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: linkedArtifacts,
            withDestinationURL: realArtifacts
        )
        defer { try? FileManager.default.removeItem(at: parent) }

        let realExecutable = parent.appendingPathComponent("benchmark-driver")
        let linkedExecutable = parent.appendingPathComponent("linked-benchmark-driver")
        try Data("renderer executable".utf8).write(to: realExecutable)
        try FileManager.default.createSymbolicLink(
            at: linkedExecutable,
            withDestinationURL: realExecutable
        )
        var job = makeJob()
        job.rendererExecutableSHA256 = try MetalOffscreenRenderer.sha256(fileAt: realExecutable)
        let driver = BenchmarkRenderDriver { _, _, _ in
            XCTFail("A rejected trust root must not render.")
            return self.digest("f")
        }

        XCTAssertThrowsError(
            try driver.execute(
                job: job,
                artifactRoot: linkedArtifacts,
                manifestURL: linkedArtifacts.appendingPathComponent("rendering-manifest.json"),
                rendererExecutableURL: realExecutable
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("real directory"),
                error.localizedDescription
            )
        }

        XCTAssertThrowsError(
            try driver.execute(
                job: job,
                artifactRoot: realArtifacts,
                manifestURL: realArtifacts.appendingPathComponent("rendering-manifest.json"),
                rendererExecutableURL: linkedExecutable
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("regular file"),
                error.localizedDescription
            )
        }
    }

    private func makeJob() -> BenchmarkRenderJob {
        let holdouts = [4, 9]
        let job = BenchmarkRenderJob(
            schemaVersion: 2,
            sceneID: "orbit-01",
            scale: 12,
            requestDigest: digest("0"),
            inputDigest: digest("2"),
            rendererClosureSHA256: digest("8"),
            rendererExecutableSHA256: digest("7"),
            groundTruthPreparation: GroundTruthPreparationBinding(
                path: "ground-truth-preparation.json",
                sha256: digest("1")
            ),
            holdoutIndices: holdouts,
            trainingViewIndices: (0..<12).filter { !holdouts.contains($0) },
            candidateCheckout: CheckoutBinding(path: "/tmp/candidate", commit: String(repeating: "a", count: 40)),
            baselineCheckout: CheckoutBinding(path: "/tmp/baseline", commit: String(repeating: "b", count: 40)),
            views: holdouts.map { index in
                RenderViewJob(
                    holdoutIndex: index,
                    camera: RenderCamera(
                        width: 64,
                        height: 64,
                        projectionMatrixColumnMajor: identity,
                        worldToCameraMatrixColumnMajor: identity
                    ),
                    groundTruth: GroundTruthImage(
                        path: "rendering/ground-truth/\(index).png",
                        sha256: digest("3"),
                        sourcePath: "rendering/source/\(index).png",
                        sourceSHA256: digest("a"),
                        preparationViewSHA256: digest("9")
                    ),
                    sources: RenderVariant.allCases.map { variant in
                        RenderSource(
                            variant: variant,
                            runID: "\(variant.rawValue)-run",
                            checkoutCommit: variant == .pairedBaseline
                                ? String(repeating: "b", count: 40)
                                : String(repeating: "a", count: 40),
                            toolchainIdentity: digest("4"),
                            sourceExecutableSHA256: digest("6"),
                            plyPath: "sources/\(variant.rawValue).ply",
                            plySHA256: digest("5"),
                            outputPath: "rendering/\(variant.rawValue)/\(index).png"
                        )
                    }
                )
            }
        )
        return job
    }

    private func makeDriverFixture() throws -> DriverFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let candidate = try makeCheckout(at: root.appendingPathComponent("candidate"))
        let baseline = try makeCheckout(at: root.appendingPathComponent("baseline"))
        let artifacts = root.appendingPathComponent("artifacts", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("benchmark-driver")
        try Data("renderer executable".utf8).write(to: executable)
        var job = makeJob()
        job.candidateCheckout = CheckoutBinding(path: candidate.root.path, commit: candidate.commit)
        job.baselineCheckout = CheckoutBinding(path: baseline.root.path, commit: baseline.commit)
        job.rendererExecutableSHA256 = try MetalOffscreenRenderer.sha256(fileAt: executable)
        let preparation = artifacts.appendingPathComponent("ground-truth-preparation.json")
        try Data("preparation".utf8).write(to: preparation)
        job.groundTruthPreparation = GroundTruthPreparationBinding(
            path: "ground-truth-preparation.json",
            sha256: try MetalOffscreenRenderer.sha256(fileAt: preparation)
        )
        for variant in RenderVariant.allCases {
            let source = artifacts.appendingPathComponent("sources/\(variant.rawValue).ply")
            try FileManager.default.createDirectory(
                at: source.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("ply \(variant.rawValue)".utf8).write(to: source)
        }
        for viewIndex in job.views.indices {
            let holdout = job.views[viewIndex].holdoutIndex
            let groundTruth = artifacts.appendingPathComponent(
                "rendering/ground-truth/\(holdout).png"
            )
            let groundTruthSource = artifacts.appendingPathComponent(
                "rendering/source/\(holdout).png"
            )
            try FileManager.default.createDirectory(
                at: groundTruth.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("ground truth \(holdout)".utf8).write(to: groundTruth)
            try FileManager.default.createDirectory(
                at: groundTruthSource.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("ground truth source \(holdout)".utf8).write(to: groundTruthSource)
            job.views[viewIndex].groundTruth = GroundTruthImage(
                path: "rendering/ground-truth/\(holdout).png",
                sha256: try MetalOffscreenRenderer.sha256(fileAt: groundTruth),
                sourcePath: "rendering/source/\(holdout).png",
                sourceSHA256: try MetalOffscreenRenderer.sha256(fileAt: groundTruthSource),
                preparationViewSHA256: digest("9")
            )
            for sourceIndex in job.views[viewIndex].sources.indices {
                let variant = job.views[viewIndex].sources[sourceIndex].variant
                let sourcePath = "sources/\(variant.rawValue).ply"
                let source = artifacts.appendingPathComponent(sourcePath)
                job.views[viewIndex].sources[sourceIndex].runID = "\(variant.rawValue)-run"
                job.views[viewIndex].sources[sourceIndex].checkoutCommit =
                    variant == .pairedBaseline ? baseline.commit : candidate.commit
                job.views[viewIndex].sources[sourceIndex].plyPath = sourcePath
                job.views[viewIndex].sources[sourceIndex].plySHA256 =
                    try MetalOffscreenRenderer.sha256(fileAt: source)
                job.views[viewIndex].sources[sourceIndex].outputPath =
                    "rendering/\(variant.rawValue)/\(holdout).png"
            }
        }
        return DriverFixture(
            root: root,
            artifacts: artifacts,
            executable: executable,
            job: job
        )
    }

    private var identity: [Float] {
        [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        ]
    }

    private var perspectiveProjection: [Float] {
        [
            1.732_050_8, 0, 0, 0,
            0, 1.732_050_8, 0, 0,
            0, 0, -1.002_002, -1,
            0, 0, -0.200_200_2, 0,
        ]
    }

    private var translatedView: [Float] {
        [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, -3, 1,
        ]
    }

    private var minimalSplatPLY: String {
        """
        ply
        format ascii 1.0
        element vertex 1
        property float x
        property float y
        property float z
        property float f_dc_0
        property float f_dc_1
        property float f_dc_2
        property float scale_0
        property float scale_1
        property float scale_2
        property float opacity
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        0 0 0 1 0 0 -2 -2 -2 3 1 0 0 0
        """
    }

    private func digest(_ character: Character) -> String {
        "sha256:" + String(repeating: String(character), count: 64)
    }

    private func runGit(_ arguments: [String], at root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func makeCheckout(at root: URL) throws -> CheckoutSnapshot {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runGit(["init", "--quiet"], at: root)
        try "fixture\n".write(
            to: root.appendingPathComponent("fixture.txt"),
            atomically: true,
            encoding: .utf8
        )
        try runGit(["add", "fixture.txt"], at: root)
        try runGit(
            [
                "-c", "user.name=EasySplat Tests",
                "-c", "user.email=tests@easysplat.invalid",
                "commit", "--quiet", "-m", "fixture",
            ],
            at: root
        )
        return try CheckoutSnapshot.capture(root: root)
    }
}

private struct DriverFixture {
    let root: URL
    let artifacts: URL
    let executable: URL
    let job: BenchmarkRenderJob
}

private struct RenderCameraDigestFixture: Decodable {
    let schemaVersion: Int
    let camera: RenderCamera
    let digest: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case camera, digest
    }
}

private final class StubLoadedScene: LoadedSceneRendering {
    private let body: (RenderCamera, URL) throws -> String
    let splatCount: Int

    init(splatCount: Int = 0, body: @escaping (RenderCamera, URL) throws -> String) {
        self.splatCount = splatCount
        self.body = body
    }

    func render(camera: RenderCamera, outputURL: URL) throws -> String {
        try body(camera, outputURL)
    }
}
