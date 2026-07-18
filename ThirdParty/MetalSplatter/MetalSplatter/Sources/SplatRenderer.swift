import Accelerate
import Foundation
import Metal
import MetalKit
import SplatIO

public class SplatRenderer {
    private enum ReadError: LocalizedError {
        case incomplete
        case callbackWithoutActiveRead
        case failureWithoutError

        var errorDescription: String? {
            switch self {
            case .incomplete:
                "Splat reader returned before completing"
            case .callbackWithoutActiveRead:
                "Splat reader callback arrived without an active read"
            case .failureWithoutError:
                "Splat reader failed without an error"
            }
        }
    }

    private enum SplatEncodingError: LocalizedError {
        case invalidAdditionalCapacity(Int)
        case mixedColorEncodings
        case sphericalHarmonicCapacityOverflow

        var errorDescription: String? {
            switch self {
            case .invalidAdditionalCapacity(let count):
                "Additional splat capacity cannot be negative (\(count))."
            case .mixedColorEncodings:
                "A splat scene cannot mix full spherical-harmonic and fixed-color points."
            case .sphericalHarmonicCapacityOverflow:
                "The spherical-harmonic coefficient buffer is too large."
            }
        }
    }

    public enum SortFailure: LocalizedError, Sendable, Equatable {
        case orderBufferAllocationFailed(String)
        case sceneResetAllocationFailed(String)
        case temporaryBufferAllocationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .orderBufferAllocationFailed(let detail):
                "Could not allocate a sorted splat-order buffer: \(detail)"
            case .sceneResetAllocationFailed(let detail):
                "Could not allocate empty splat scene storage: \(detail)"
            case .temporaryBufferAllocationFailed(let detail):
                "Could not allocate temporary splat-sort storage: \(detail)"
            }
        }
    }

    private struct SortCamera: Equatable {
        let position: SIMD3<Float>
        let forward: SIMD3<Float>
    }

    private struct SortContext {
        let generation: UInt64
        let camera: SortCamera
        let splatBuffer: MTLBuffer
        let splatCount: Int
        let startedAt: Date
        let orderBufferCapacityLimit: Int?
    }

    enum Constants {
        // Keep in sync with Shaders.metal : maxViewCount
        static let maxViewCount = 2
        // Euclidean distance avoids the camera-turn artifacts produced by forward-depth sorting.
        static let sortByDistance = true
        // Keep the scalar CPU sorter as the single production path.
        static let useAccelerateForSort = false
        static let renderFrontToBack = true
    }

    private static let log =
        Logger(subsystem: Bundle.module.bundleIdentifier ?? "MetalSplatter",
               category: "SplatRenderer")

    public struct CameraDescriptor {
        public var projectionMatrix: simd_float4x4
        public var viewMatrix: simd_float4x4
        public var screenSize: SIMD2<Int>

        public init(projectionMatrix: simd_float4x4, viewMatrix: simd_float4x4, screenSize: SIMD2<Int>) {
            self.projectionMatrix = projectionMatrix
            self.viewMatrix = viewMatrix
            self.screenSize = screenSize
        }
    }

    // Keep in sync with Shaders.metal : BufferIndex
    enum BufferIndex: NSInteger {
        case uniforms          = 0
        case splat             = 1
        case order             = 2
        case sphericalHarmonic = 3
    }

    enum SHDegree: UInt32 {
        case sh0 = 0
        case sh3 = 3

        // Full-SH payload: one raw DC RGB triplet followed by 15 higher-order triplets.
        static let payloadCount = 16
    }

    // Keep in sync with Shaders.metal : Uniforms
    struct Uniforms {
        var projectionMatrix: matrix_float4x4
        var viewMatrix: matrix_float4x4
        var cameraWorldPosition: MTLPackedFloat3
        var sphericalHarmonicDegree: UInt32
        var screenSize: SIMD2<UInt32> // Size of screen in pixels
    }

    // Keep in sync with Shaders.metal : UniformsArray
    struct UniformsArray {
        // maxViewCount = 2, so we have 2 entries
        var uniforms0: Uniforms
        var uniforms1: Uniforms

        // The 256 byte aligned size of our uniform structure
        static var alignedSize: Int { (MemoryLayout<UniformsArray>.size + 0xFF) & -0x100 }

        mutating func setUniforms(index: Int, _ uniforms: Uniforms) {
            switch index {
            case 0: uniforms0 = uniforms
            case 1: uniforms1 = uniforms
            default: break
            }
        }
    }

    struct PackedHalf3 {
        var x: Float16
        var y: Float16
        var z: Float16
    }

    struct PackedRGBHalf4 {
        var r: Float16
        var g: Float16
        var b: Float16
        var a: Float16
    }

    // Keep in sync with Shaders.metal : Vertex
    struct Splat {
        var position: MTLPackedFloat3
        var color: PackedRGBHalf4
        var covA: PackedHalf3
        var covB: PackedHalf3
    }

    struct SplatIndexAndDepth {
        var index: UInt32
        var depth: Float
    }

    struct RenderSceneSnapshot {
        let splatBuffer: MTLBuffer
        let splatCount: Int
        let orderBuffer: MTLBuffer
        let sphericalHarmonicCoefficientBuffer: MTLBuffer
        let sphericalHarmonicDegree: SHDegree
    }

    var pipelineState: MTLRenderPipelineState
    var depthState: MTLDepthStencilState
    public let maxViewCount: Int
    public let maxSimultaneousRenders: Int

    public var onSortStart: (() -> Void)?
    public var onSortComplete: ((TimeInterval) -> Void)?
    public var onSortFailure: ((SortFailure) -> Void)?
    var onSortSnapshotCapturedForTesting: ((MTLBuffer) -> Void)?
    var onSortWorkerBufferBoundForTesting: ((MTLBuffer) -> Void)?

    // dynamicUniformBuffers contains maxSimultaneousRenders uniforms buffers,
    // which we round-robin through, one per render; this is managed by switchToNextDynamicBuffer.
    // uniforms = the i'th buffer (where i = uniformBufferIndex, which varies from 0 to maxSimultaneousRenders-1)
    var dynamicUniformBuffers: MTLBuffer
    var uniformBufferOffset = 0
    var uniformBufferIndex = 0
    var uniforms: UnsafeMutablePointer<UniformsArray>

    // cameraWorldPosition and Forward vectors are the latest mean camera position across all viewports
    var cameraWorldPosition: SIMD3<Float> = .zero
    var cameraWorldForward: SIMD3<Float> = .init(x: 0, y: 0, z: -1)

    typealias IndexType = UInt32
    // splatBuffer contains one entry for each gaussian splat
    var splatBuffer: MetalBuffer<Splat>
    // Full-SH scenes store raw DC plus 15 basis-major RGB triplets per splat. SH0 scenes keep this nil.
    var sphericalHarmonicCoefficientBuffer: MetalBuffer<PackedHalf3>?
    var sphericalHarmonicDegree: SHDegree = .sh0
    private let emptySphericalHarmonicCoefficientBuffer: MetalBuffer<PackedHalf3>
    // orderBuffer indexes into splatBuffer, and is sorted by distance
    var orderBuffer: MetalBuffer<IndexType>

    public var splatCount: Int { withSortStateLock { splatBuffer.count } }

    var sorting = false
    private let sortStateLock = NSLock()
    private var sceneGeneration: UInt64 = 0
    private var lastScheduledSortCamera: SortCamera?
    var sortedOrderBufferCapacityLimit: Int?

    // Sorting via Accelerate
    // While not sorting, we guarantee that orderBufferTempSort remains valid: the count may not match splatCount, but for every i in 0..<orderBufferTempSort.count, orderBufferTempSort should contain exactly one element equal to i
    var orderBufferTempSort: MetalBuffer<UInt>
    // depthBufferTempSort is ordered by vertex index; so depthBufferTempSort[0] -> splatBuffer[0], *not* orderBufferTempSort[0]
    var depthBufferTempSort: MetalBuffer<Float>

    // Sorting on CPU
    // While not sorting, we guarantee that orderAndDepthTempSort remains valid: the count may not match splatCount, but the array should contain all indices.
    // So for every i in 0..<orderAndDepthTempSort.count, orderAndDepthTempSort should contain exactly one element with .index = i
    var orderAndDepthTempSort: [SplatIndexAndDepth] = []

    private let maximumSplatCount: Int?
    private var readFailure: Error?
    private var pendingSplatBuffer: MetalBuffer<Splat>?
    private var pendingSphericalHarmonicCoefficientBuffer: MetalBuffer<PackedHalf3>?
    private var pendingSphericalHarmonicDegree: SHDegree = .sh0
    private var readFinished = false

    public convenience init(device: MTLDevice,
                            colorFormat: MTLPixelFormat,
                            depthFormat: MTLPixelFormat,
                            stencilFormat: MTLPixelFormat,
                            sampleCount: Int,
                            maxViewCount: Int,
                            maxSimultaneousRenders: Int) throws {
        try self.init(
            device: device,
            colorFormat: colorFormat,
            depthFormat: depthFormat,
            stencilFormat: stencilFormat,
            sampleCount: sampleCount,
            maxViewCount: maxViewCount,
            maxSimultaneousRenders: maxSimultaneousRenders,
            maximumSplatCount: nil
        )
    }

    init(device: MTLDevice,
         colorFormat: MTLPixelFormat,
         depthFormat: MTLPixelFormat,
         stencilFormat: MTLPixelFormat,
         sampleCount: Int,
         maxViewCount: Int,
         maxSimultaneousRenders: Int,
         maximumSplatCount: Int?) throws {
        self.maxViewCount = min(maxViewCount, Constants.maxViewCount)
        self.maxSimultaneousRenders = maxSimultaneousRenders
        self.maximumSplatCount = maximumSplatCount

        let dynamicUniformBuffersSize = UniformsArray.alignedSize * maxSimultaneousRenders
        self.dynamicUniformBuffers = device.makeBuffer(length: dynamicUniformBuffersSize,
                                                       options: .storageModeShared)!
        self.dynamicUniformBuffers.label = "Uniform Buffers"
        self.uniforms = UnsafeMutableRawPointer(dynamicUniformBuffers.contents()).bindMemory(to: UniformsArray.self, capacity: 1)

        self.splatBuffer = try MetalBuffer(device: device, maximumCapacity: maximumSplatCount)
        self.sphericalHarmonicCoefficientBuffer = nil
        self.emptySphericalHarmonicCoefficientBuffer = try MetalBuffer(device: device)
        self.orderBuffer = try MetalBuffer(device: device)
        self.orderBufferTempSort = try MetalBuffer(device: device)
        self.depthBufferTempSort = try MetalBuffer(device: device)
        self.sortedOrderBufferCapacityLimit = nil

        pipelineState = try Self.buildRenderPipelineWithDevice(device: device,
                                                               colorFormat: colorFormat,
                                                               depthFormat: depthFormat,
                                                               stencilFormat: stencilFormat,
                                                               sampleCount: sampleCount,
                                                               maxViewCount: self.maxViewCount)

        let depthStateDescriptor = MTLDepthStencilDescriptor()
        depthStateDescriptor.depthCompareFunction = MTLCompareFunction.lessEqual
        depthStateDescriptor.isDepthWriteEnabled = false
        self.depthState = device.makeDepthStencilState(descriptor:depthStateDescriptor)!
    }

    public func reset() {
        do {
            let emptySplats = try MetalBuffer<Splat>(
                device: splatBuffer.device,
                maximumCapacity: maximumSplatCount
            )
            let emptyOrder = try makeOrderBuffer(
                device: splatBuffer.device,
                count: 0,
                maximumCapacity: nil,
                indexAt: { _ in 0 }
            )
            withSortStateLock {
                splatBuffer = emptySplats
                sphericalHarmonicCoefficientBuffer = nil
                sphericalHarmonicDegree = .sh0
                orderBuffer = emptyOrder
                sceneGeneration &+= 1
                lastScheduledSortCamera = nil
            }
        } catch {
            recordSortFailure(.sceneResetAllocationFailed(error.localizedDescription))
        }
    }

    public func readPLY(from url: URL) throws {
        try readPLY(from: url, shouldCancel: { false })
    }

    public func readPLY(
        from url: URL,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws {
        try readScene(shouldCancel: shouldCancel) { delegate in
            SplatPLYSceneReader(
                url,
                validatesRenderEncoding: false
            ).read(to: delegate, shouldCancel: shouldCancel)
        }
    }

    func readScene(
        shouldCancel: @escaping @Sendable () -> Bool,
        using read: (_ delegate: SplatSceneReaderDelegate) -> Void
    ) throws {
        readFailure = nil
        readFinished = false
        let pendingSplatBuffer = try MetalBuffer<Splat>(
            device: splatBuffer.device,
            maximumCapacity: maximumSplatCount
        )
        self.pendingSplatBuffer = pendingSplatBuffer
        self.pendingSphericalHarmonicCoefficientBuffer = nil
        self.pendingSphericalHarmonicDegree = .sh0
        defer {
            self.pendingSplatBuffer = nil
            self.pendingSphericalHarmonicCoefficientBuffer = nil
            self.pendingSphericalHarmonicDegree = .sh0
            self.readFailure = nil
            self.readFinished = false
        }

        read(self)
        if let readFailure {
            throw readFailure
        }
        if shouldCancel() {
            throw CancellationError()
        }
        guard readFinished else {
            throw ReadError.incomplete
        }

        let identityOrder = try makeOrderBuffer(
            device: pendingSplatBuffer.device,
            count: pendingSplatBuffer.count,
            maximumCapacity: nil,
            indexAt: { UInt32($0) }
        )
        publishScene(
            splats: pendingSplatBuffer,
            sphericalHarmonics: pendingSphericalHarmonicCoefficientBuffer,
            degree: pendingSphericalHarmonicDegree,
            order: identityOrder
        )
    }

    private class func buildRenderPipelineWithDevice(device: MTLDevice,
                                                     colorFormat: MTLPixelFormat,
                                                     depthFormat: MTLPixelFormat,
                                                     stencilFormat: MTLPixelFormat,
                                                     sampleCount: Int,
                                                     maxViewCount: Int) throws -> MTLRenderPipelineState {
        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: Bundle.module)
        } catch {
            // SwiftPM does not always build a default .metallib for `.metal` files included as
            // resources, which causes `makeDefaultLibrary(bundle:)` to fail at runtime.
            // Fall back to compiling from the packaged shader source.
            guard let shaderURL = Bundle.module.url(forResource: "Shaders", withExtension: "metal") else {
                throw error
            }
            let source = try String(contentsOf: shaderURL, encoding: .utf8)
            library = try device.makeLibrary(source: source, options: nil)
        }

        let vertexFunction = library.makeFunction(name: "splatVertexShader")
        let fragmentFunction = library.makeFunction(name: "splatFragmentShader")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "RenderPipeline"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction

        pipelineDescriptor.rasterSampleCount = sampleCount

        let colorAttachment = pipelineDescriptor.colorAttachments[0]!
        colorAttachment.pixelFormat = colorFormat
        colorAttachment.isBlendingEnabled = true
        colorAttachment.rgbBlendOperation = .add
        colorAttachment.alphaBlendOperation = .add
        if Constants.renderFrontToBack {
            colorAttachment.sourceRGBBlendFactor = .oneMinusDestinationAlpha
            colorAttachment.sourceAlphaBlendFactor = .oneMinusDestinationAlpha
            colorAttachment.destinationRGBBlendFactor = .one
            colorAttachment.destinationAlphaBlendFactor = .one
        } else {
            colorAttachment.sourceRGBBlendFactor = .one
            colorAttachment.sourceAlphaBlendFactor = .one
            colorAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            colorAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        pipelineDescriptor.colorAttachments[0] = colorAttachment

        pipelineDescriptor.depthAttachmentPixelFormat = depthFormat
        pipelineDescriptor.stencilAttachmentPixelFormat = stencilFormat

        pipelineDescriptor.maxVertexAmplificationCount = maxViewCount

        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    public func ensureAdditionalCapacity(_ pointCount: Int) throws {
        try withSortStateLock {
            guard pointCount >= 0 else {
                throw SplatEncodingError.invalidAdditionalCapacity(pointCount)
            }
            let targetCount = splatBuffer.count.addingReportingOverflow(pointCount)
            guard !targetCount.overflow else {
                throw SplatEncodingError.sphericalHarmonicCapacityOverflow
            }
            try splatBuffer.ensureCapacity(targetCount.partialValue)
            if let sphericalHarmonicCoefficientBuffer {
                try sphericalHarmonicCoefficientBuffer.ensureCapacity(
                    Self.sphericalHarmonicCoefficientCount(for: targetCount.partialValue)
                )
            }
        }
    }

    public func add(_ point: SplatScenePoint) throws {
        let validated = try SplatRenderEncodingValidator.encode(point)
        let encoded = Splat(validated)
        try withSortStateLock {
            try Self.validateColorEncoding(
                usesFullSphericalHarmonics: validated.sphericalHarmonics != nil,
                existingPointCount: splatBuffer.count,
                degree: sphericalHarmonicDegree
            )
            let newCount = splatBuffer.count + 1
            try splatBuffer.ensureCapacity(newCount)
            let identityOrder = try makeOrderBuffer(
                device: splatBuffer.device,
                count: newCount,
                maximumCapacity: nil,
                indexAt: { UInt32($0) }
            )
            var coefficients = sphericalHarmonicCoefficientBuffer
            var degree = sphericalHarmonicDegree
            try Self.appendSphericalHarmonics(
                payload: validated.sphericalHarmonics,
                existingPointCount: splatBuffer.count,
                targetPointCapacity: splatBuffer.capacity,
                device: splatBuffer.device,
                maximumCoefficientCount: try maximumSphericalHarmonicCoefficientCount(),
                buffer: &coefficients,
                degree: &degree
            )
            sphericalHarmonicCoefficientBuffer = coefficients
            sphericalHarmonicDegree = degree
            splatBuffer.append(encoded)
            orderBuffer = identityOrder
            sceneGeneration &+= 1
            lastScheduledSortCamera = nil
        }
    }

    public func willRender(viewportCameras: [CameraDescriptor]) {
        let camera = SortCamera(
            position: viewportCameras.map { Self.cameraWorldPosition(forViewMatrix: $0.viewMatrix) }.mean ?? .zero,
            forward: viewportCameras.map { Self.cameraWorldForward(forViewMatrix: $0.viewMatrix) }.mean?.normalized
                ?? .init(x: 0, y: 0, z: -1)
        )
        cameraWorldPosition = camera.position
        cameraWorldForward = camera.forward
        resortIndicesIfCameraChanged(camera)
    }

    private func switchToNextDynamicBuffer() {
        uniformBufferIndex = (uniformBufferIndex + 1) % maxSimultaneousRenders
        uniformBufferOffset = UniformsArray.alignedSize * uniformBufferIndex
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffers.contents() + uniformBufferOffset).bindMemory(to: UniformsArray.self, capacity: 1)
    }

    private func updateUniforms(
        forViewportCameras viewportCameras: [CameraDescriptor],
        sphericalHarmonicDegree: SHDegree
    ) {
        for (i, viewportCamera) in viewportCameras.prefix(maxViewCount).enumerated() {
            let cameraPosition = Self.cameraWorldPosition(forViewMatrix: viewportCamera.viewMatrix)
            let uniforms = Uniforms(projectionMatrix: viewportCamera.projectionMatrix,
                                    viewMatrix: viewportCamera.viewMatrix,
                                    cameraWorldPosition: MTLPackedFloat3Make(
                                        cameraPosition.x,
                                        cameraPosition.y,
                                        cameraPosition.z
                                    ),
                                    sphericalHarmonicDegree: sphericalHarmonicDegree.rawValue,
                                    screenSize: SIMD2(x: UInt32(viewportCamera.screenSize.x), y: UInt32(viewportCamera.screenSize.y)))
            self.uniforms.pointee.setUniforms(index: i, uniforms)
        }
    }

    private static func cameraWorldForward(forViewMatrix view: simd_float4x4) -> simd_float3 {
        (view.inverse * SIMD4<Float>(x: 0, y: 0, z: -1, w: 0)).xyz
    }

    private static func cameraWorldPosition(forViewMatrix view: simd_float4x4) -> simd_float3 {
        (view.inverse * SIMD4<Float>(x: 0, y: 0, z: 0, w: 1)).xyz
    }

    public func render(viewportCameras: [CameraDescriptor], to renderEncoder: MTLRenderCommandEncoder) {
        guard let capturedScene = captureRenderScene() else { return }
        render(
            viewportCameras: viewportCameras,
            capturedScene: capturedScene,
            to: renderEncoder
        )
    }

    func captureRenderScene() -> RenderSceneSnapshot? {
        withSortStateLock {
            guard splatBuffer.count != 0 else { return nil }
            return RenderSceneSnapshot(
                splatBuffer: splatBuffer.buffer,
                splatCount: splatBuffer.count,
                orderBuffer: orderBuffer.buffer,
                sphericalHarmonicCoefficientBuffer:
                    sphericalHarmonicCoefficientBuffer?.buffer
                    ?? emptySphericalHarmonicCoefficientBuffer.buffer,
                sphericalHarmonicDegree: sphericalHarmonicDegree
            )
        }
    }

    func render(
        viewportCameras: [CameraDescriptor],
        capturedScene: RenderSceneSnapshot,
        to renderEncoder: MTLRenderCommandEncoder
    ) {

        switchToNextDynamicBuffer()
        updateUniforms(
            forViewportCameras: viewportCameras,
            sphericalHarmonicDegree: capturedScene.sphericalHarmonicDegree
        )

        renderEncoder.pushDebugGroup("Draw Splat Model")

        renderEncoder.setRenderPipelineState(pipelineState)

        renderEncoder.setDepthStencilState(depthState)

        renderEncoder.setVertexBuffer(dynamicUniformBuffers, offset: uniformBufferOffset, index: BufferIndex.uniforms.rawValue)
        renderEncoder.setVertexBuffer(
            capturedScene.splatBuffer,
            offset: 0,
            index: BufferIndex.splat.rawValue
        )
        renderEncoder.setVertexBuffer(
            capturedScene.orderBuffer,
            offset: 0,
            index: BufferIndex.order.rawValue
        )
        renderEncoder.setVertexBuffer(
            capturedScene.sphericalHarmonicCoefficientBuffer,
            offset: 0,
            index: BufferIndex.sphericalHarmonic.rawValue
        )

        renderEncoder.drawPrimitives(type: .triangleStrip,
                                     vertexStart: 0,
                                     vertexCount: 4,
                                     instanceCount: capturedScene.splatCount)

        renderEncoder.popDebugGroup()
    }

    public func resortIndices() {
        if Constants.useAccelerateForSort {
            resortIndicesViaAccelerate()
        } else {
            resortIndicesOnCPU()
        }
    }

    public func resortIndicesOnCPU() {
        resortIndicesOnCPU(camera: currentSortCamera, force: true)
    }

    public func resortIndicesViaAccelerate() {
        resortIndicesViaAccelerate(camera: currentSortCamera, force: true)
    }

    private var currentSortCamera: SortCamera {
        SortCamera(position: cameraWorldPosition, forward: cameraWorldForward)
    }

    private func resortIndicesIfCameraChanged(_ camera: SortCamera) {
        if Constants.useAccelerateForSort {
            resortIndicesViaAccelerate(camera: camera, force: false)
        } else {
            resortIndicesOnCPU(camera: camera, force: false)
        }
    }

    private func resortIndicesOnCPU(camera: SortCamera, force: Bool) {
        guard let context = beginSort(camera: camera, force: force) else { return }
        onSortSnapshotCapturedForTesting?(context.splatBuffer)
        onSortStart?()

        var workingOrder = orderAndDepthTempSort
        orderAndDepthTempSort = []
        if workingOrder.count != context.splatCount {
            workingOrder = Array(
                repeating: SplatIndexAndDepth(index: .max, depth: 0),
                count: context.splatCount
            )
            for index in workingOrder.indices {
                workingOrder[index].index = UInt32(index)
            }
        }

        Task(priority: .high) { [self, context, workingOrder] in
            var workingOrder = workingOrder
            let splatValues = sortSplatValues(for: context)
            for index in workingOrder.indices {
                let splatIndex = workingOrder[index].index
                let splatPosition = splatValues[Int(splatIndex)].position
                let splatPositionUnpacked = SIMD3<Float>(splatPosition.x, splatPosition.y, splatPosition.z)
                if Constants.sortByDistance {
                    workingOrder[index].depth = (splatPositionUnpacked - context.camera.position).lengthSquared
                } else {
                    workingOrder[index].depth = dot(splatPositionUnpacked, context.camera.forward)
                }
            }

            if Constants.renderFrontToBack {
                workingOrder.sort { $0.depth < $1.depth }
            } else {
                workingOrder.sort { $0.depth > $1.depth }
            }

            orderAndDepthTempSort = workingOrder
            do {
                let sortedOrder = try makeOrderBuffer(
                    device: context.splatBuffer.device,
                    count: context.splatCount,
                    maximumCapacity: context.orderBufferCapacityLimit,
                    indexAt: { workingOrder[$0].index }
                )
                finishSort(context, publishedOrder: sortedOrder, failure: nil)
            } catch {
                finishSort(
                    context,
                    publishedOrder: nil,
                    failure: .orderBufferAllocationFailed(error.localizedDescription)
                )
            }
        }
    }

    private func resortIndicesViaAccelerate(camera: SortCamera, force: Bool) {
        guard let context = beginSort(camera: camera, force: force) else { return }
        onSortSnapshotCapturedForTesting?(context.splatBuffer)
        onSortStart?()
        let orderScratch = orderBufferTempSort
        let depthScratch = depthBufferTempSort

        if orderScratch.count != context.splatCount || depthScratch.count != context.splatCount {
            do {
                try orderScratch.ensureCapacity(context.splatCount)
                try depthScratch.ensureCapacity(context.splatCount)
                orderScratch.count = context.splatCount
                depthScratch.count = context.splatCount

                for index in 0..<context.splatCount {
                    orderScratch.values[index] = UInt(index)
                }
            } catch {
                finishSort(
                    context,
                    publishedOrder: nil,
                    failure: .temporaryBufferAllocationFailed(error.localizedDescription)
                )
                return
            }
        }

        Task(priority: .high) { [self, context, orderScratch, depthScratch] in
            let splatValues = sortSplatValues(for: context)
            // Depth remains scalar in this opt-in path; vDSP performs the indexed sort below.
            for index in 0..<context.splatCount {
                let splatPosition = splatValues[index].position
                let splatPositionUnpacked = SIMD3<Float>(splatPosition.x, splatPosition.y, splatPosition.z)
                if Constants.sortByDistance {
                    depthScratch.values[index] = (splatPositionUnpacked - context.camera.position).lengthSquared
                } else {
                    depthScratch.values[index] = dot(splatPositionUnpacked, context.camera.forward)
                }
            }

            vDSP_vsorti(depthScratch.values,
                        orderScratch.values,
                        nil,
                        vDSP_Length(context.splatCount),
                        Constants.renderFrontToBack ? 1 : -1)

            do {
                let sortedOrder = try makeOrderBuffer(
                    device: context.splatBuffer.device,
                    count: context.splatCount,
                    maximumCapacity: context.orderBufferCapacityLimit,
                    indexAt: { UInt32(orderScratch.values[$0]) }
                )
                finishSort(context, publishedOrder: sortedOrder, failure: nil)
            } catch {
                finishSort(
                    context,
                    publishedOrder: nil,
                    failure: .orderBufferAllocationFailed(error.localizedDescription)
                )
            }
        }
    }

    private func beginSort(camera: SortCamera, force: Bool) -> SortContext? {
        withSortStateLock {
            guard !sorting else { return nil }
            guard splatBuffer.count > 0 else { return nil }
            if !force, lastScheduledSortCamera == camera {
                return nil
            }
            sorting = true
            lastScheduledSortCamera = camera
            return SortContext(
                generation: sceneGeneration,
                camera: camera,
                splatBuffer: splatBuffer.buffer,
                splatCount: splatBuffer.count,
                startedAt: Date(),
                orderBufferCapacityLimit: sortedOrderBufferCapacityLimit
            )
        }
    }

    private func finishSort(
        _ context: SortContext,
        publishedOrder: MetalBuffer<IndexType>?,
        failure: SortFailure?
    ) {
        let isCurrentGeneration = withSortStateLock {
            let isCurrent = context.generation == sceneGeneration
            if isCurrent, let publishedOrder {
                orderBuffer = publishedOrder
            }
            sorting = false
            return isCurrent
        }

        if isCurrentGeneration, let failure {
            recordSortFailure(failure)
        }
        onSortComplete?(-context.startedAt.timeIntervalSinceNow)
    }

    private func sortSplatValues(for context: SortContext) -> UnsafeMutablePointer<Splat> {
        onSortWorkerBufferBoundForTesting?(context.splatBuffer)
        return UnsafeMutableRawPointer(context.splatBuffer.contents())
            .bindMemory(to: Splat.self, capacity: context.splatCount)
    }

    private func makeOrderBuffer(
        device: MTLDevice,
        count: Int,
        maximumCapacity: Int?,
        indexAt: (Int) -> IndexType
    ) throws -> MetalBuffer<IndexType> {
        guard count <= Int(UInt32.max) else {
            throw SortFailure.orderBufferAllocationFailed("The scene contains too many splats to index.")
        }
        let buffer = try MetalBuffer<IndexType>(
            device: device,
            capacity: max(1, count),
            maximumCapacity: maximumCapacity
        )
        for index in 0..<count {
            buffer.append(indexAt(index))
        }
        return buffer
    }

    private func recordSortFailure(_ failure: SortFailure) {
        Self.log.error("Failed to update splat ordering: \(failure.localizedDescription)")
        onSortFailure?(failure)
    }

    private func withSortStateLock<T>(_ body: () throws -> T) rethrows -> T {
        sortStateLock.lock()
        defer { sortStateLock.unlock() }
        return try body()
    }

    private func publishScene(
        splats: MetalBuffer<Splat>,
        sphericalHarmonics: MetalBuffer<PackedHalf3>?,
        degree: SHDegree,
        order: MetalBuffer<IndexType>
    ) {
        withSortStateLock {
            splatBuffer = splats
            sphericalHarmonicCoefficientBuffer = sphericalHarmonics
            sphericalHarmonicDegree = degree
            orderBuffer = order
            sceneGeneration &+= 1
            lastScheduledSortCamera = nil
        }
    }

    private static func appendSphericalHarmonics(
        payload: SplatRenderSphericalHarmonics?,
        existingPointCount: Int,
        targetPointCapacity: Int,
        device: MTLDevice,
        maximumCoefficientCount: Int?,
        buffer: inout MetalBuffer<PackedHalf3>?,
        degree: inout SHDegree
    ) throws {
        if payload != nil, buffer == nil {
            guard existingPointCount == 0 else {
                throw SplatEncodingError.mixedColorEncodings
            }
            let capacity = try sphericalHarmonicCoefficientCount(for: targetPointCapacity)
            let newBuffer = try MetalBuffer<PackedHalf3>(
                device: device,
                capacity: max(1, capacity),
                maximumCapacity: maximumCoefficientCount
            )
            buffer = newBuffer
            degree = .sh3
        }

        guard let buffer else { return }
        let requiredCount = try sphericalHarmonicCoefficientCount(for: existingPointCount + 1)
        try buffer.ensureCapacity(requiredCount)
        if let payload {
            for index in 0..<SplatRenderSphericalHarmonics.coefficientCount {
                let coefficient = payload[index]
                buffer.append(PackedHalf3(
                    x: Float16(coefficient.x),
                    y: Float16(coefficient.y),
                    z: Float16(coefficient.z)
                ))
            }
        } else {
            throw SplatEncodingError.mixedColorEncodings
        }
    }

    private static func validateColorEncoding(
        usesFullSphericalHarmonics: Bool,
        existingPointCount: Int,
        degree: SHDegree
    ) throws {
        guard existingPointCount > 0 else { return }
        guard usesFullSphericalHarmonics == (degree == .sh3) else {
            throw SplatEncodingError.mixedColorEncodings
        }
    }

    private func maximumSphericalHarmonicCoefficientCount() throws -> Int? {
        guard let maximumSplatCount else { return nil }
        return try Self.sphericalHarmonicCoefficientCount(for: maximumSplatCount)
    }

    private static func sphericalHarmonicCoefficientCount(for splatCount: Int) throws -> Int {
        let result = splatCount.multipliedReportingOverflow(by: SHDegree.payloadCount)
        guard !result.overflow else {
            throw SplatEncodingError.sphericalHarmonicCapacityOverflow
        }
        return result.partialValue
    }
}

extension SplatRenderer: SplatSceneReaderDelegate {
    public func didStartReading(withPointCount pointCount: UInt32) {
        Self.log.info("Will read \(pointCount) points")
        guard let pendingSplatBuffer else {
            recordReadFailure(ReadError.callbackWithoutActiveRead)
            return
        }
        do {
            try pendingSplatBuffer.ensureCapacity(Int(pointCount))
        } catch {
            recordReadFailure(error)
        }
    }

    public func didRead(points: [SplatIO.SplatScenePoint]) {
        guard readFailure == nil else { return }
        guard let pendingSplatBuffer else {
            recordReadFailure(ReadError.callbackWithoutActiveRead)
            return
        }
        do {
            try pendingSplatBuffer.ensureCapacity(pendingSplatBuffer.count + points.count)
            for point in points {
                let validated = try SplatRenderEncodingValidator.encode(point)
                let encoded = Splat(validated)
                try Self.validateColorEncoding(
                    usesFullSphericalHarmonics: validated.sphericalHarmonics != nil,
                    existingPointCount: pendingSplatBuffer.count,
                    degree: pendingSphericalHarmonicDegree
                )
                var coefficients = pendingSphericalHarmonicCoefficientBuffer
                var degree = pendingSphericalHarmonicDegree
                try Self.appendSphericalHarmonics(
                    payload: validated.sphericalHarmonics,
                    existingPointCount: pendingSplatBuffer.count,
                    targetPointCapacity: pendingSplatBuffer.capacity,
                    device: pendingSplatBuffer.device,
                    maximumCoefficientCount: try maximumSphericalHarmonicCoefficientCount(),
                    buffer: &coefficients,
                    degree: &degree
                )
                pendingSphericalHarmonicCoefficientBuffer = coefficients
                pendingSphericalHarmonicDegree = degree
                pendingSplatBuffer.append(encoded)
            }
        } catch {
            recordReadFailure(error)
        }
    }

    public func didFinishReading() {
        readFinished = true
        Self.log.info("Finished reading points")
    }

    public func didFailReading(withError error: Error?) {
        recordReadFailure(error ?? ReadError.failureWithoutError)
    }

    private func recordReadFailure(_ error: Error) {
        guard readFailure == nil else { return }
        readFailure = error
        Self.log.error("Failed to read points: \(error.localizedDescription)")
    }
}

extension SplatRenderer.Splat {
    init(_ encoding: SplatRenderEncoding) {
        let color = encoding.linearColorOpacity
        let covA = encoding.covarianceA
        let covB = encoding.covarianceB
        self.init(
            position: MTLPackedFloat3Make(
                encoding.position.x,
                encoding.position.y,
                encoding.position.z
            ),
            color: SplatRenderer.PackedRGBHalf4(
                r: Float16(color.x),
                g: Float16(color.y),
                b: Float16(color.z),
                a: Float16(color.w)
            ),
            covA: SplatRenderer.PackedHalf3(
                x: Float16(covA.x),
                y: Float16(covA.y),
                z: Float16(covA.z)
            ),
            covB: SplatRenderer.PackedHalf3(
                x: Float16(covB.x),
                y: Float16(covB.y),
                z: Float16(covB.z)
            )
        )
    }
}

protocol MTLIndexTypeProvider {
    static var asMTLIndexType: MTLIndexType { get }
}

extension UInt32: MTLIndexTypeProvider {
    static var asMTLIndexType: MTLIndexType { .uint32 }
}
extension UInt16: MTLIndexTypeProvider {
    static var asMTLIndexType: MTLIndexType { .uint16 }
}

extension Array where Element == SIMD3<Float> {
    var mean: SIMD3<Float>? {
        guard !isEmpty else { return nil }
        return reduce(.zero, +) / Float(count)
    }
}

private extension SIMD3 where Scalar: BinaryFloatingPoint, Scalar.RawSignificand: FixedWidthInteger {
    var normalized: SIMD3<Scalar> {
        self / Scalar(sqrt(lengthSquared))
    }

    var lengthSquared: Scalar {
        x*x + y*y + z*z
    }

    func vector4(w: Scalar) -> SIMD4<Scalar> {
        SIMD4<Scalar>(x: x, y: y, z: z, w: w)
    }

    static func random(in range: Range<Scalar>) -> SIMD3<Scalar> {
        Self(x: Scalar.random(in: range), y: .random(in: range), z: .random(in: range))
    }
}

private extension SIMD4 where Scalar: BinaryFloatingPoint {
    var xyz: SIMD3<Scalar> {
        .init(x: x, y: y, z: z)
    }
}
