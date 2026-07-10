#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatCore

/// Records how many idle-sleep assertions were taken and released so tests can prove the
/// pipeline holds exactly one for the whole run and always balances it on exit. Shared
/// across the integration tests via internal visibility.
final class RecordingPowerAssertion: PowerAssertionManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var _begun = 0
    private var _released = 0
    private var _active = 0

    var begun: Int { lock.lock(); defer { lock.unlock() }; return _begun }
    var released: Int { lock.lock(); defer { lock.unlock() }; return _released }
    var active: Int { lock.lock(); defer { lock.unlock() }; return _active }

    func beginPreventingIdleSleep(reason: String) -> PowerAssertionHandle {
        lock.lock(); _begun += 1; _active += 1; lock.unlock()
        return Handle { [weak self] in self?.recordRelease() }
    }

    private func recordRelease() {
        lock.lock(); _released += 1; _active -= 1; lock.unlock()
    }

    /// Fires its release callback at most once, mirroring the real handle's idempotency.
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

final class PowerAssertionTests: XCTestCase {
    func testSystemPowerAssertionReleaseIsIdempotent() {
        let assertion = SystemPowerAssertion()
        let handle = assertion.beginPreventingIdleSleep(reason: "unit test")
        // Releasing twice must not crash or double-call endActivity.
        handle.release()
        handle.release()
    }

    func testRecordingAssertionHandleIsIdempotent() {
        let recorder = RecordingPowerAssertion()
        let handle = recorder.beginPreventingIdleSleep(reason: "unit test")
        XCTAssertEqual(recorder.begun, 1)
        XCTAssertEqual(recorder.released, 0)
        XCTAssertEqual(recorder.active, 1)
        handle.release()
        handle.release()
        XCTAssertEqual(recorder.released, 1, "Release must be recorded exactly once even if called twice.")
        XCTAssertEqual(recorder.active, 0)
    }
}
#endif
