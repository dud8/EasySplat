import Darwin
import Foundation

enum SecureLogFileHandle {
    private enum OpenError: Error {
        case cannotOpen(Int32)
        case notRegularFile
    }

    static func openForAppending(at url: URL) throws -> FileHandle {
        try open(at: url, append: true, truncate: false)
    }

    static func openForReplacing(at url: URL) throws -> FileHandle {
        try open(at: url, append: false, truncate: true)
    }

    private static func open(at url: URL, append: Bool, truncate: Bool) throws -> FileHandle {
        let accessFlags = append ? O_APPEND : 0
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | accessFlags | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { throw OpenError.cannotOpen(errno) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw OpenError.notRegularFile
        }
        if truncate, ftruncate(descriptor, 0) != 0 {
            let code = errno
            Darwin.close(descriptor)
            throw OpenError.cannotOpen(code)
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}

/// Minimal, append-only tool log file writer used to persist external tool stdout/stderr to disk.
/// We keep this separate from `pipeline.log` so users can inspect raw-ish tool output when needed.
final class ToolLogWriter: @unchecked Sendable {
    private static let timestampLock = NSLock()
    private nonisolated(unsafe) static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func timestamp() -> String {
        timestampLock.lock()
        defer { timestampLock.unlock() }
        return timestampFormatter.string(from: Date())
    }

    private let fileURL: URL
    private let toolName: String
    private let lock = NSLock()
    private var handle: FileHandle?
    private var lastLineByStream: [String: String] = [:]

    init(fileURL: URL, toolName: String) {
        self.fileURL = fileURL
        self.toolName = toolName
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // O_APPEND preserves earlier stages while O_NOFOLLOW rejects a malicious leaf
        // symlink instead of sending tool output outside the project bundle.
        let opened = try? SecureLogFileHandle.openForAppending(at: fileURL)
        self.handle = opened
        if self.handle == nil {
            FileHandle.standardError.write(Data("ToolLogWriter[\(toolName)]: failed to open log at \(fileURL.path)\n".utf8))
        }
    }

    deinit {
        try? handle?.close()
    }

    func beginSection(title: String, metadata: [String: String] = [:]) {
        let now = Self.timestamp()
        var lines: [String] = []
        lines.append("")
        lines.append("=== \(now) \(toolName) \(title) ===")
        for (key, value) in metadata.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key): \(value)")
        }
        write(lines.joined(separator: "\n") + "\n")
    }

    func append(stream: String, line: String) {
        let cleaned = Self.stripAnsi(from: line)
        guard !cleaned.isEmpty else { return }

        // Avoid writing exact duplicates from noisy redraw loops.
        lock.lock()
        if lastLineByStream[stream] == cleaned {
            lock.unlock()
            return
        }
        lastLineByStream[stream] = cleaned
        lock.unlock()

        let now = Self.timestamp()
        write("[\(now)][\(stream)] \(cleaned)\n")
    }

    private func write(_ text: String) {
        guard let data = text.data(using: .utf8), !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }

    private static func stripAnsi(from text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)

        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch == "\u{001B}" {
                index = text.index(after: index)
                // Skip CSI sequences: ESC [ ... <final byte>
                if index < text.endIndex, text[index] == "[" {
                    index = text.index(after: index)
                    while index < text.endIndex {
                        let c = text[index]
                        if (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") {
                            index = text.index(after: index)
                            break
                        }
                        index = text.index(after: index)
                    }
                }
                continue
            }

            // Remove other control chars (except tab) to keep logs readable.
            if ch == "\t" || ch >= " " {
                result.append(ch)
            }
            index = text.index(after: index)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
