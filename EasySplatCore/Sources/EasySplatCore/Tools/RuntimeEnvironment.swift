@preconcurrency import Darwin
import Foundation

@_silgen_name("_NSGetEnviron")
private func currentEnvironmentPointer() -> UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>

enum RuntimeEnvironment {
    static var current: [String: String] {
        access.snapshot()
    }

    static func value(forKey key: String) -> String? {
        access.value(forKey: key)
    }

    static func setValue(_ value: String?, forKey key: String) {
        access.setValue(value, forKey: key)
    }

    private static let access = LockedAccess()
}

private final class LockedAccess: @unchecked Sendable {
    private let lock = NSLock()
    private var mutatedKeys: Set<String> = []

    func snapshot() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }

        // `setenv` may reallocate the environment table. The imported `environ`
        // binding can retain the old pointer on older Darwin runtimes, while
        // `_NSGetEnviron` always returns the process's current table.
        guard var entry = currentEnvironmentPointer().pointee else { return [:] }
        var environment: [String: String] = [:]

        while let item = entry.pointee {
            let pair = String(cString: item).split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            if pair.count == 2 {
                environment[String(pair[0])] = String(pair[1])
            }
            entry = entry.advanced(by: 1)
        }

        // On older runtimes even the current table can briefly retain an older entry.
        // `getenv` is authoritative for keys changed in-process, including removals.
        for key in mutatedKeys {
            if let value = getenv(key) {
                environment[key] = String(cString: value)
            } else {
                environment.removeValue(forKey: key)
            }
        }
        return environment
    }

    func value(forKey key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return getenv(key).map { String(cString: $0) }
    }

    func setValue(_ value: String?, forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        mutatedKeys.insert(key)
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }
}
