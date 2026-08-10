import Foundation

public struct CheckoutSnapshot: Equatable, Sendable {
    public let root: URL
    public let commit: String

    public static func capture(root: URL) throws -> CheckoutSnapshot {
        var isDirectory = ObjCBool(false)
        guard root.isFileURL,
              !root.path.isEmpty,
              FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              (try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw BenchmarkDriverError.invalidJob("A benchmark checkout is not a real directory.")
        }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let topLevel = try git(["rev-parse", "--show-toplevel"], root: resolvedRoot)
        guard URL(fileURLWithPath: topLevel).standardizedFileURL == resolvedRoot else {
            throw BenchmarkDriverError.invalidJob("A benchmark checkout must point to its worktree root.")
        }
        let commit = try git(["rev-parse", "HEAD"], root: resolvedRoot)
        guard BenchmarkRenderJob.isCommit(commit) else {
            throw BenchmarkDriverError.invalidJob("A benchmark checkout commit is invalid.")
        }
        guard try git(["status", "--porcelain", "--untracked-files=normal"], root: resolvedRoot).isEmpty else {
            throw BenchmarkDriverError.checkoutChanged("The benchmark checkout is not clean.")
        }
        return CheckoutSnapshot(root: resolvedRoot, commit: commit)
    }

    /// The commit and cleanliness of a checkout, without the refusal `capture` performs.
    ///
    /// Release evidence may only come from a clean tree, which is why `capture` throws. A
    /// research measurement is often the whole point of an uncommitted change, so it records
    /// the dirty flag and lets the comparison decide: statistics from a dirty tree are
    /// readable, an acceptance from one is not.
    public static func describe(root: URL) throws -> (commit: String, dirty: Bool) {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let commit = try git(["rev-parse", "HEAD"], root: resolvedRoot)
        guard BenchmarkRenderJob.isCommit(commit) else {
            throw BenchmarkDriverError.invalidJob("A benchmark checkout commit is invalid.")
        }
        let status = try git(["status", "--porcelain", "--untracked-files=normal"], root: resolvedRoot)
        return (commit, !status.isEmpty)
    }

    public func verifyUnchanged() throws {
        let currentCommit = try Self.git(["rev-parse", "HEAD"], root: root)
        let status = try Self.git(["status", "--porcelain", "--untracked-files=normal"], root: root)
        guard currentCommit == commit, status.isEmpty else {
            throw BenchmarkDriverError.checkoutChanged("The benchmark checkout changed during rendering.")
        }
    }

    private static func git(_ arguments: [String], root: URL) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            throw BenchmarkDriverError.invalidJob("A benchmark checkout could not be inspected.")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BenchmarkDriverError.invalidJob("A benchmark checkout could not be inspected.")
        }
        return String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
