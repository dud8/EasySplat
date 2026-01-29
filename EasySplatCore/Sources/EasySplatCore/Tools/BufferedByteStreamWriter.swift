import Foundation

/// Streams `UInt8` bytes into a file efficiently (buffered), with best-effort cleanup on failure.
struct BufferedByteStreamWriter {
    let fileManager: FileManager
    var bufferSize: Int = 64 * 1024

    func write<S: AsyncSequence>(
        bytes: S,
        to destination: URL,
        expectedLength: Int64,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws where S.Element == UInt8 {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = fileManager.createFile(atPath: destination.path, contents: nil)

        let handle = try FileHandle(forWritingTo: destination)
        var received: Int64 = 0
        var buffer: [UInt8] = []
        buffer.reserveCapacity(bufferSize)

        do {
            defer { try? handle.close() }

            for try await byte in bytes {
                buffer.append(byte)
                received += 1

                if buffer.count >= bufferSize {
                    try handle.write(contentsOf: Data(buffer))
                    buffer.removeAll(keepingCapacity: true)

                    if expectedLength > 0 {
                        onProgress(Double(received) / Double(expectedLength), "Downloading toolchain")
                    }
                }
            }

            if !buffer.isEmpty {
                try handle.write(contentsOf: Data(buffer))
            }

            if expectedLength > 0 {
                onProgress(1.0, "Downloading toolchain")
            }
        } catch {
            try? handle.close()
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }
}

