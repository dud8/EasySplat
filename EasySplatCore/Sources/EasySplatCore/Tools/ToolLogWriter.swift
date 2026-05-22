import Foundation

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
        // Only create when missing — multiple ToolLogWriter instances for the same file
        // (e.g. consecutive COLMAP stages within one pipeline run) must append, not clobber
        // each other. `beginSection` writes a timestamped banner so sections are still
        // visually separable.
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        let opened = try? FileHandle(forWritingTo: fileURL)
        // Position at end so the first write doesn't overwrite earlier content.
        _ = try? opened?.seekToEnd()
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
