import Foundation
@testable import EasySplatCore

private actor EnvironmentLock {
    static let shared = EnvironmentLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func unlock() {
        if waiters.isEmpty {
            locked = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }
}

@discardableResult
func withEnvironmentAsync<T: Sendable>(
    _ changes: [String: String?],
    isolation: isolated (any Actor)? = #isolation,
    _ body: () async throws -> T
) async rethrows -> T {
    await EnvironmentLock.shared.lock()
    let previous = captureEnvironment(changes)
    applyEnvironment(changes)
    do {
        let result = try await body()
        restoreEnvironment(previous)
        await EnvironmentLock.shared.unlock()
        return result
    } catch {
        restoreEnvironment(previous)
        await EnvironmentLock.shared.unlock()
        throw error
    }
}

@discardableResult
func scopedEnvironment(
    _ changes: [String: String?],
    isolation: isolated (any Actor)? = #isolation
) async -> @Sendable () -> Void {
    await EnvironmentLock.shared.lock()
    let previous = captureEnvironment(changes)
    applyEnvironment(changes)
    return {
        restoreEnvironment(previous)
        Task { await EnvironmentLock.shared.unlock() }
    }
}

private func captureEnvironment(_ changes: [String: String?]) -> [String: String?] {
    var previous: [String: String?] = [:]
    for key in changes.keys {
        previous[key] = RuntimeEnvironment.value(forKey: key)
    }
    return previous
}

private func applyEnvironment(_ changes: [String: String?]) {
    for (key, value) in changes {
        RuntimeEnvironment.setValue(value, forKey: key)
    }
}

private func restoreEnvironment(_ previous: [String: String?]) {
    for (key, value) in previous {
        RuntimeEnvironment.setValue(value, forKey: key)
    }
}
