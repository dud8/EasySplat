import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum TestFileBuilder {
    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    static func createFile(at url: URL, data: Data = Data()) {
        FileManager.default.createFile(atPath: url.path, contents: data)
    }

    static func createTextFile(at url: URL, text: String) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func createExecutable(at url: URL, script: String? = "#!/usr/bin/env bash\nexit 0\n") throws {
        try createDirectory(url.deletingLastPathComponent())
        if let script {
            try script.write(to: url, atomically: true, encoding: .utf8)
        } else {
            createFile(at: url)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static func writeGrayscaleImage(url: URL, size: Int, value: UInt8, utType: UTType) throws -> Bool {
        let width = size
        let height = size
        let bytesPerRow = width
        var pixels = [UInt8](repeating: value, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let data = Data(bytes: &pixels, count: pixels.count)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return false
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, utType.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        return CGImageDestinationFinalize(destination)
    }

    static func writeMinimalPly(at url: URL, vertexCount: Int = 1) throws {
        let safeCount = max(1, vertexCount)
        let body = (0..<safeCount).map { _ in "0 0 0" }.joined(separator: "\n")
        let text = """
        ply
        format ascii 1.0
        element vertex \(safeCount)
        property float x
        property float y
        property float z
        end_header
        \(body)
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
