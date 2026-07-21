#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatApp
@testable import EasySplatCore

/// App-side recorder (the core test target's copy is in a different module).
final class RecordingPowerAssertion: PowerAssertionManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var _begun = 0
    private var _released = 0
    private var _preflightObservedActive: Bool?

    var begun: Int { lock.lock(); defer { lock.unlock() }; return _begun }
    var released: Int { lock.lock(); defer { lock.unlock() }; return _released }
    var preflightObservedActive: Bool? {
        lock.lock(); defer { lock.unlock() }
        return _preflightObservedActive
    }

    func beginPreventingIdleSleep(reason: String) -> PowerAssertionHandle {
        lock.lock(); _begun += 1; lock.unlock()
        return Handle { [weak self] in self?.record() }
    }

    func recordPreflightObservation() {
        lock.lock()
        _preflightObservedActive = _begun > _released
        lock.unlock()
    }

    private func record() { lock.lock(); _released += 1; lock.unlock() }

    private final class Handle: PowerAssertionHandle, @unchecked Sendable {
        private let lock = NSLock()
        private var onRelease: (() -> Void)?
        init(onRelease: @escaping () -> Void) { self.onRelease = onRelease }
        func release() {
            lock.lock(); let callback = onRelease; onRelease = nil; lock.unlock()
            callback?()
        }
    }
}

@MainActor
final class AppModelPowerAssertionTests: XCTestCase {
    func testStartProjectHoldsAndReleasesAssertionAcrossPreflightToolchainAndRun() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let recorder = RecordingPowerAssertion()
        let videoInputPreflight = VideoInputPreflight(
            limits: .init(
                maximumVideoCount: 1,
                maximumTotalBytes: 1_024,
                minimumFreeSpaceReserveBytes: 0,
                maximumConcurrentDecoders: 1
            ),
            availableCapacity: { _ in Int64.max },
            analyze: { _, _ in
                recorder.recordPreflightObservation()
                return VideoInputAnalysisEvidence(
                    trackID: 1,
                    pixelWidth: 64,
                    pixelHeight: 48,
                    durationSeconds: 1,
                    nominalFrameRate: 30,
                    isHDR: false,
                    decodedFrameCount: 3,
                    preferredTransform: .identity
                )
            }
        )
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            videoInputPreflight: videoInputPreflight,
            pipelineRunnerFactory: { projectURL, config in
                MockPipelineRunner(projectURL: projectURL, config: config)
            },
            powerAssertion: recorder
        )

        model.addInputs(urls: [input])
        model.startFromPendingSelection()

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, model.viewState != .viewer {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(model.viewState, .viewer, "Mock start should reach the viewer.")

        XCTAssertEqual(recorder.preflightObservedActive, true)
        XCTAssertEqual(recorder.begun, 1)
        XCTAssertEqual(recorder.released, 1)
    }

    func testStartProjectReleasesAssertionOnceWhenPreflightFails() async throws {
        let tempBase = try makeTemporaryVideoFixture()
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let recorder = RecordingPowerAssertion()
        let preflight = VideoInputPreflight(
            limits: testLimits,
            availableCapacity: { _ in Int64.max },
            analyze: { _, _ in
                recorder.recordPreflightObservation()
                throw InjectedPreflightFailure()
            }
        )
        let model = makeModel(base: tempBase, preflight: preflight, recorder: recorder)

        _ = await model.startProject(
            input: .video(files: [tempBase.appendingPathComponent("input.mov").path]),
            title: "Preflight failure"
        )

        XCTAssertEqual(recorder.preflightObservedActive, true)
        XCTAssertEqual(recorder.begun, 1)
        XCTAssertEqual(recorder.released, 1)
    }

    func testStartProjectReleasesAssertionOnceWhenPreflightIsCancelled() async throws {
        let tempBase = try makeTemporaryVideoFixture()
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let recorder = RecordingPowerAssertion()
        let probe = PreflightCancellationProbe()
        let preflight = VideoInputPreflight(
            limits: testLimits,
            availableCapacity: { _ in Int64.max },
            analyze: { _, _ in
                recorder.recordPreflightObservation()
                return try await probe.waitForCancellation()
            }
        )
        let model = makeModel(base: tempBase, preflight: preflight, recorder: recorder)
        let task = Task { @MainActor in
            await model.startProject(
                input: .video(files: [tempBase.appendingPathComponent("input.mov").path]),
                title: "Cancelled preflight"
            )
        }

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, !(await probe.hasStarted()) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let didStart = await probe.hasStarted()
        XCTAssertTrue(didStart)
        task.cancel()
        _ = await task.value

        XCTAssertEqual(recorder.preflightObservedActive, true)
        XCTAssertEqual(recorder.begun, 1)
        XCTAssertEqual(recorder.released, 1)
    }

    private var testLimits: VideoInputPreflightLimits {
        .init(
            maximumVideoCount: 1,
            maximumTotalBytes: 1_024,
            minimumFreeSpaceReserveBytes: 0,
            maximumConcurrentDecoders: 1
        )
    }

    private func makeTemporaryVideoFixture() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("video".utf8).write(to: base.appendingPathComponent("input.mov"))
        return base
    }

    private func makeModel(
        base: URL,
        preflight: VideoInputPreflight,
        recorder: RecordingPowerAssertion
    ) -> AppModel {
        AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: base,
            videoInputPreflight: preflight,
            pipelineRunnerFactory: { projectURL, config in
                MockPipelineRunner(projectURL: projectURL, config: config)
            },
            powerAssertion: recorder
        )
    }
}

private struct InjectedPreflightFailure: Error {}

private actor PreflightCancellationProbe {
    private var started = false

    func hasStarted() -> Bool { started }

    func waitForCancellation() async throws -> VideoInputAnalysisEvidence {
        started = true
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
#endif
