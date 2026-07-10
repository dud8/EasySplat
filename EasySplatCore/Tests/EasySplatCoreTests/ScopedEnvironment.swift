import Foundation

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

@MainActor
@discardableResult
func withEnvironmentAsync<T: Sendable>(
    _ changes: [String: String?],
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

@MainActor
@discardableResult
func scopedEnvironment(_ changes: [String: String?]) async -> @Sendable () -> Void {
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
        if let value = getenv(key) {
            previous[key] = String(cString: value)
        } else {
            previous[key] = nil
        }
    }
    return previous
}

private func applyEnvironment(_ changes: [String: String?]) {
    for (key, value) in changes {
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }
}

private func restoreEnvironment(_ previous: [String: String?]) {
    for (key, value) in previous {
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }
}
