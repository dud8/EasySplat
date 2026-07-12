import Foundation

/// Prevents the Mac from going to sleep during a long operation.
///
/// EasySplat runs can be lengthy (geometry plus native splat training), and a
/// foreground SwiftUI app does not by itself keep the system awake. Without an assertion,
/// macOS idle sleep can kill a run partway through — training in particular has no
/// resumable optimizer checkpoint, so a sleep-kill loses the whole session.
///
/// The assertion prevents *system* idle sleep only; the display is still allowed to sleep,
/// so an unattended overnight run does not burn the screen.
public protocol PowerAssertionManaging: Sendable {
    /// Begin an assertion that keeps the system awake. Balance every call with `release()`
    /// on the returned handle (a `defer` at the call site is the intended pattern).
    func beginPreventingIdleSleep(reason: String) -> PowerAssertionHandle
}

/// A held power assertion. `release()` must be idempotent. The system implementation also
/// releases on dealloc as a backstop, so a leaked handle cannot pin the machine awake
/// indefinitely; other conformers are not required to provide that backstop.
public protocol PowerAssertionHandle: Sendable {
    /// Releases the assertion. Must be safe to call more than once.
    func release()
}

/// Real implementation backed by `ProcessInfo.beginActivity`, the recommended high-level
/// API for this on macOS (no IOKit assertion bookkeeping required).
public struct SystemPowerAssertion: PowerAssertionManaging {
    public init() {}

    public func beginPreventingIdleSleep(reason: String) -> PowerAssertionHandle {
        let token = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .userInitiated],
            reason: reason
        )
        return SystemPowerAssertionHandle(token: token)
    }
}

private final class SystemPowerAssertionHandle: PowerAssertionHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var token: NSObjectProtocol?

    init(token: NSObjectProtocol) {
        self.token = token
    }

    func release() {
        lock.lock()
        let pending = token
        token = nil
        lock.unlock()
        if let pending {
            ProcessInfo.processInfo.endActivity(pending)
        }
    }

    deinit {
        release()
    }
}
