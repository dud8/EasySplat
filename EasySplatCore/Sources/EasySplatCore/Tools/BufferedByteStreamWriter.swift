import Foundation

/// Streams `UInt8` bytes into a file efficiently (buffered), with best-effort cleanup on failure.
struct BufferedByteStreamWriter {
    let fileManager: FileManager
    var bufferSize: Int = 64 * 1024

    func write<S: AsyncSequence>(
        bytes: S,
        to destination: URL,
        expectedLength: Int64,
        label: String,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws where S.Element == UInt8 {
        func formatBytes(_ value: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
        }

        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = fileManager.createFile(atPath: destination.path, contents: nil)

        let handle = try FileHandle(forWritingTo: destination)
        var received: Int64 = 0
        var buffer: [UInt8] = []
        buffer.reserveCapacity(bufferSize)
        let startedAt = Date()
        var lastUpdate = Date.distantPast

        do {
            defer { try? handle.close() }

            for try await byte in bytes {
                buffer.append(byte)
                received += 1

                if buffer.count >= bufferSize {
                    try handle.write(contentsOf: Data(buffer))
                    buffer.removeAll(keepingCapacity: true)

                    if expectedLength > 0, Date().timeIntervalSince(lastUpdate) >= 0.2 {
                        lastUpdate = Date()
                        let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
                        let rate = Int64(Double(received) / elapsed)
                        let message = "\(label) \(formatBytes(received))/\(formatBytes(expectedLength)) (\(formatBytes(rate))/s)"
                        onProgress(Double(received) / Double(expectedLength), message)
                    }
                }
            }

            if !buffer.isEmpty {
                try handle.write(contentsOf: Data(buffer))
            }

            if expectedLength > 0 {
                let elapsed = max(Date().timeIntervalSince(startedAt), 0.001)
                let rate = Int64(Double(received) / elapsed)
                let message = "\(label) \(formatBytes(received))/\(formatBytes(expectedLength)) (\(formatBytes(rate))/s)"
                onProgress(1.0, message)
            }
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }
}
