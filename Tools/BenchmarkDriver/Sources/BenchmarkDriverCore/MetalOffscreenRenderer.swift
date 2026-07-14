import CoreGraphics
import CryptoKit
import EasySplatCore
import Foundation
import ImageIO
import Metal
import simd
import MetalSplatter
import UniformTypeIdentifiers

public final class MetalOffscreenRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let sortTimeout: DispatchTimeInterval

    public init(
        device: MTLDevice? = MTLCreateSystemDefaultDevice(),
        sortTimeout: DispatchTimeInterval = .seconds(30)
    ) throws {
        guard let device else { throw BenchmarkDriverError.metalUnavailable }
        guard let commandQueue = device.makeCommandQueue() else {
            throw BenchmarkDriverError.renderFailed("Metal could not create a command queue.")
        }
        self.device = device
        self.commandQueue = commandQueue
        self.sortTimeout = sortTimeout
    }

    @discardableResult
    public func render(plyURL: URL, camera: RenderCamera, outputURL: URL) throws -> String {
        guard case .valid = ProjectArtifactValidator.validatePlyFile(at: plyURL) else {
            throw BenchmarkDriverError.renderFailed("The render source is not a valid Gaussian PLY.")
        }
        let renderer: SplatRenderer
        do {
            renderer = try SplatRenderer(
                device: device,
                colorFormat: .rgba8Unorm_srgb,
                depthFormat: .invalid,
                stencilFormat: .invalid,
                sampleCount: 1,
                maxViewCount: 1,
                maxSimultaneousRenders: 1
            )
            try renderer.readPLY(from: plyURL)
        } catch {
            throw BenchmarkDriverError.renderFailed(
                "MetalSplatter could not load the render source: \(error.localizedDescription)"
            )
        }
        let descriptor = SplatRenderer.CameraDescriptor(
            projectionMatrix: try camera.projectionMatrix(),
            viewMatrix: try camera.worldToCameraMatrix(),
            screenSize: SIMD2(camera.width, camera.height)
        )
        try Self.awaitSort(timeout: sortTimeout) { finish in
            renderer.onSortFailure = { failure in
                finish(.failure(failure.localizedDescription))
            }
            renderer.onSortComplete = { _ in finish(.success) }
            renderer.willRender(viewportCameras: [descriptor])
        }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb,
            width: camera.width,
            height: camera.height,
            mipmapped: false
        )
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = [.renderTarget]
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            throw BenchmarkDriverError.renderFailed("Metal could not allocate the render target.")
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw BenchmarkDriverError.renderFailed("Metal could not create a command buffer.")
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw BenchmarkDriverError.renderFailed("Metal could not create a render encoder.")
        }
        renderer.render(viewportCameras: [descriptor], to: encoder)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw BenchmarkDriverError.renderFailed(
                "Metal failed while rendering the held-out view: \(error.localizedDescription)"
            )
        }

        let bytesPerRow = camera.width * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * camera.height)
        texture.getBytes(
            &rgba,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, camera.width, camera.height),
            mipmapLevel: 0
        )
        var rgb = [UInt8]()
        rgb.reserveCapacity(camera.width * camera.height * 3)
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            rgb.append(rgba[offset])
            rgb.append(rgba[offset + 1])
            rgb.append(rgba[offset + 2])
        }
        let png = try Self.pngData(rgb: rgb, width: camera.width, height: camera.height)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: outputURL, options: .atomic)
        return Self.sha256(data: png)
    }

    public static func sha256(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func awaitSort(
        timeout: DispatchTimeInterval,
        start: (@escaping @Sendable (SortOutcome) -> Void) -> Void
    ) throws {
        let signal = SortSignal()
        start { outcome in signal.finish(with: outcome) }
        guard signal.wait(timeout: timeout) else {
            throw BenchmarkDriverError.renderFailed("MetalSplatter did not finish depth sorting.")
        }
        if case .failure(let detail) = signal.outcome {
            throw BenchmarkDriverError.renderFailed("MetalSplatter could not sort the render source: \(detail)")
        }
    }

    private static func pngData(rgb: [UInt8], width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let provider = CGDataProvider(data: Data(rgb) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 24,
                bytesPerRow: width * 3,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw BenchmarkDriverError.renderFailed("The rendered pixels could not be encoded.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw BenchmarkDriverError.renderFailed("The PNG encoder is unavailable.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw BenchmarkDriverError.renderFailed("The rendered PNG could not be finalized.")
        }
        return data as Data
    }

    private static func sha256(data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum SortOutcome: Sendable {
    case success
    case failure(String)
}

private final class SortSignal: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var storedOutcome: SortOutcome?

    var outcome: SortOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return storedOutcome
    }

    func finish(with outcome: SortOutcome) {
        lock.lock()
        guard storedOutcome == nil else {
            lock.unlock()
            return
        }
        storedOutcome = outcome
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: DispatchTimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }
}

private extension RenderCamera {
    func projectionMatrix() throws -> simd_float4x4 {
        try matrix(from: projectionMatrixColumnMajor)
    }

    func worldToCameraMatrix() throws -> simd_float4x4 {
        try matrix(from: worldToCameraMatrixColumnMajor)
    }

    func matrix(from values: [Float]) throws -> simd_float4x4 {
        guard values.count == 16, values.allSatisfy(\.isFinite) else {
            throw BenchmarkDriverError.invalidJob("A render camera matrix is invalid.")
        }
        return simd_float4x4(columns: (
            SIMD4(values[0], values[1], values[2], values[3]),
            SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]),
            SIMD4(values[12], values[13], values[14], values[15])
        ))
    }
}
