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

    var begun: Int { lock.lock(); defer { lock.unlock() }; return _begun }
    var released: Int { lock.lock(); defer { lock.unlock() }; return _released }

    func beginPreventingIdleSleep(reason: String) -> PowerAssertionHandle {
        lock.lock(); _begun += 1; lock.unlock()
        return Handle { [weak self] in self?.record() }
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
    func testStartProjectHoldsAndReleasesAssertionAcrossToolchainAndRun() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let recorder = RecordingPowerAssertion()
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
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

        // The AppModel assertion wraps the toolchain download (which happens before the
        // runner exists) through the run, so at least one was held and all were released.
        XCTAssertGreaterThanOrEqual(recorder.begun, 1, "startProject must hold an idle-sleep assertion across download + run.")
        XCTAssertEqual(recorder.released, recorder.begun, "Every held idle-sleep assertion must be released.")
    }
}
#endif
