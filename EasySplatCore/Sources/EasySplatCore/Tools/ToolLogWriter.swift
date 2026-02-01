import Foundation

/// Minimal, append-only tool log file writer used to persist external tool stdout/stderr to disk.
/// We keep this separate from `pipeline.log` so users can inspect raw-ish tool output when needed.
final class ToolLogWriter: @unchecked Sendable {
    private static func timestamp() -> String {
        // Avoid static shared formatter state (not concurrency-safe).
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private let fileURL: URL
    private let toolName: String
    private let lock = NSLock()
    private var handle: FileHandle?
    private var lastLineByStream: [String: String] = [:]

    init(fileURL: URL, toolName: String) {
        self.fileURL = fileURL
        self.toolName = toolName
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        self.handle = try? FileHandle(forWritingTo: fileURL)
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
