@preconcurrency import Darwin
import Foundation

@_silgen_name("_NSGetEnviron")
private func currentEnvironmentPointer() -> UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>

enum RuntimeEnvironment {
    static var current: [String: String] {
        access.withLock {
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

            return environment
        }
    }

    static func value(forKey key: String) -> String? {
        access.withLock {
            getenv(key).map { String(cString: $0) }
        }
    }

    static func setValue(_ value: String?, forKey key: String) {
        access.withLock { () -> Void in
            if let value {
                setenv(key, value, 1)
            } else {
                unsetenv(key)
            }
        }
    }

    private static let access = LockedAccess()
}

private final class LockedAccess: @unchecked Sendable {
    private let lock = NSLock()

    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
