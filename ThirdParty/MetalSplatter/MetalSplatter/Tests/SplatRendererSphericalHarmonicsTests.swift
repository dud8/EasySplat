import Foundation
import Metal
import SplatIO
import simd
import XCTest
@testable import MetalSplatter

final class SplatRendererSphericalHarmonicsTests: XCTestCase {
    private let shC0: Float = 0.28209479177387814

    func testSplatEncodingPreservesLegacyColorAndMovesRawDCIntoSHBuffer() throws {
        let rawDC = SIMD3<Float>(0.75, -0.25, 1.5)
        let shRenderer = try makeRenderer()
        try shRenderer.add(makePoint(color: .sphericalHarmonic(
            rawDC.x,
            rawDC.y,
            rawDC.z,
            Array(repeating: 0, count: 45)
        )))
        let rgbRenderer = try makeRenderer()
        try rgbRenderer.add(makePoint(color: .linearUInt8(64, 128, 224)))
        try rgbRenderer.add(makePoint(color: .linearFloat(64.5, 128.25, 224.75)))
        XCTAssertNil(rgbRenderer.sphericalHarmonicCoefficientBuffer)
        XCTAssertEqual(rgbRenderer.sphericalHarmonicDegree, .sh0)

        assertStoredColor(
            shRenderer.splatBuffer.values[0].color,
            expectedSRGB: simd_max(shC0 * rawDC + SIMD3<Float>(repeating: 0.5), .zero)
        )
        let sh = try XCTUnwrap(shRenderer.sphericalHarmonicCoefficientBuffer)
        XCTAssertEqual(sh.count, 16)
        XCTAssertEqual(Float(sh.values[0].x), Float(Float16(rawDC.x)))
        XCTAssertEqual(Float(sh.values[0].y), Float(Float16(rawDC.y)))
        XCTAssertEqual(Float(sh.values[0].z), Float(Float16(rawDC.z)))

        assertStoredColor(
            rgbRenderer.splatBuffer.values[0].color,
            expectedSRGB: SIMD3<Float>(64, 128, 224) / 255
        )
        assertStoredColor(
            rgbRenderer.splatBuffer.values[1].color,
            expectedSRGB: SIMD3<Float>(64.5, 128.25, 224.75) / 255
        )
    }

    func testPackedSH3PayloadIsExactlyNinetySixBytesPerSplat() {
        XCTAssertEqual(MemoryLayout<SplatRenderer.PackedHalf3>.size, 6)
        XCTAssertEqual(MemoryLayout<SplatRenderer.PackedHalf3>.stride, 6)
        XCTAssertEqual(700_000 * 16 * MemoryLayout<SplatRenderer.PackedHalf3>.stride, 67_200_000)
    }

    func testChannelMajorPLYIsEvaluatedAsBasisMajorRGBTriplets() throws {
        var coefficients = Array(repeating: SIMD3<Float>.zero, count: 15)
        coefficients[0].x = 0.20
        coefficients[1].y = 0.30
        coefficients[2].z = 0.40
        let rawDC = SIMD3<Float>(0.1, -0.1, 0.05)
        let url = try makeSH3PLY(rawDC: rawDC, coefficients: coefficients)
        let renderer = try makeRenderer()
        try renderer.readPLY(from: url)
        XCTAssertEqual(renderer.sphericalHarmonicDegree, .sh3)
        let packed = try XCTUnwrap(renderer.sphericalHarmonicCoefficientBuffer)
        XCTAssertEqual(packed.count, 16)
        XCTAssertEqual(packed.buffer.length, 96)
        XCTAssertEqual(Float(packed.values[0].x), Float(Float16(rawDC.x)))
        XCTAssertEqual(Float(packed.values[0].y), Float(Float16(rawDC.y)))
        XCTAssertEqual(Float(packed.values[0].z), Float(Float16(rawDC.z)))
        for basis in 0..<15 {
            XCTAssertEqual(Float(packed.values[basis + 1].x), Float(Float16(coefficients[basis].x)))
            XCTAssertEqual(Float(packed.values[basis + 1].y), Float(Float16(coefficients[basis].y)))
            XCTAssertEqual(Float(packed.values[basis + 1].z), Float(Float16(coefficients[basis].z)))
        }
        let direction = simd_normalize(SIMD3<Float>(0.3, 0.5, 0.8))

        let actual = try renderCenterPixel(renderer: renderer, direction: direction)
        let expected = evaluate(rawDC: rawDC, coefficients: coefficients, direction: direction)

        assertEqual(actual, expected, accuracy: 0.002)
    }

    func testGPUColorMatchesFloat32SH0ThroughSH3Equations() throws {
        let coefficients = (0..<15).map { index in
            let n = Float(index + 1)
            return SIMD3<Float>(0.011 * n, -0.006 * n, 0.008 * n)
        }
        let rawDC = SIMD3<Float>(0.12, -0.08, 0.03)
        let url = try makeSH3PLY(rawDC: rawDC, coefficients: coefficients)
        let renderer = try makeRenderer()
        try renderer.readPLY(from: url)
        let directions: [SIMD3<Float>] = [
            SIMD3<Float>(1, 0, 0),
            SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(0, 0, 1),
            simd_normalize(SIMD3<Float>(1, 2, 3)),
            simd_normalize(SIMD3<Float>(-2, 1, -1)),
        ]

        for direction in directions {
            let actual = try renderCenterPixel(renderer: renderer, direction: direction)
            let expected = evaluate(rawDC: rawDC, coefficients: coefficients, direction: direction)
            assertEqual(actual, expected, accuracy: 0.002, "direction \(direction)")
        }
    }

    func testOddBandsUseCameraToSplatDirection() throws {
        var coefficients = Array(repeating: SIMD3<Float>.zero, count: 15)
        coefficients[1].x = 0.5
        let rawDC = SIMD3<Float>.zero
        let url = try makeSH3PLY(rawDC: rawDC, coefficients: coefficients)
        let renderer = try makeRenderer()
        try renderer.readPLY(from: url)

        let positiveZ = try renderCenterPixel(renderer: renderer, direction: SIMD3<Float>(0, 0, 1))
        let negativeZ = try renderCenterPixel(renderer: renderer, direction: SIMD3<Float>(0, 0, -1))

        XCTAssertGreaterThan(positiveZ.x, negativeZ.x)
        assertEqual(
            positiveZ,
            evaluate(rawDC: rawDC, coefficients: coefficients, direction: SIMD3<Float>(0, 0, 1)),
            accuracy: 0.002
        )
        assertEqual(
            negativeZ,
            evaluate(rawDC: rawDC, coefficients: coefficients, direction: SIMD3<Float>(0, 0, -1)),
            accuracy: 0.002
        )
    }

    func testCoincidentCameraUsesFiniteDeterministicDirection() throws {
        var coefficients = Array(repeating: SIMD3<Float>.zero, count: 15)
        coefficients[1] = SIMD3<Float>(0.3, -0.2, 0.1)
        let rawDC = SIMD3<Float>(0.1, 0.1, 0.1)
        let position = SIMD3<Float>(0, 0, -3)
        let url = try makeSH3PLY(rawDC: rawDC, coefficients: coefficients, position: position)
        let renderer = try makeRenderer()
        try renderer.readPLY(from: url)
        let projectiveView = simd_float4x4(columns: (
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(0, 0, 1.5, 0.5)
        ))

        let first = try renderCenterPixel(renderer: renderer, viewMatrix: projectiveView)
        let second = try renderCenterPixel(renderer: renderer, viewMatrix: projectiveView)

        XCTAssertTrue(first.x.isFinite && first.y.isFinite && first.z.isFinite)
        XCTAssertEqual(first, second)
        assertEqual(
            first,
            evaluate(rawDC: rawDC, coefficients: coefficients, direction: SIMD3<Float>(0, 0, 1)),
            accuracy: 0.002
        )
    }

    func testMalformedReplacementPreservesPublishedSHSceneAndRender() throws {
        let renderer = try loadedDirectionalRenderer()
        let direction = simd_normalize(SIMD3<Float>(0.3, 0.5, 0.8))
        let before = try snapshot(renderer: renderer, direction: direction)
        let malformed = try makeSH3PLY(
            rawDC: SIMD3<Float>(0.2, 0.1, 0),
            coefficients: Array(repeating: .zero, count: 15),
            omitFinalValue: true,
            validPointBeforeMalformedPoint: true
        )

        XCTAssertThrowsError(try renderer.readPLY(from: malformed))

        let after = try snapshot(renderer: renderer, direction: direction)
        XCTAssertEqual(after, before)
    }

    func testCancelledReplacementPreservesPublishedSHSceneAndRender() throws {
        let renderer = try loadedDirectionalRenderer()
        let direction = simd_normalize(SIMD3<Float>(0.3, 0.5, 0.8))
        let before = try snapshot(renderer: renderer, direction: direction)
        let probe = SHCancellationProbe()
        let replacementPoint = makePoint(color: .sphericalHarmonic(
            0.2,
            0.1,
            0,
            Array(repeating: 0, count: 45)
        ))

        XCTAssertThrowsError(
            try renderer.readScene(
                shouldCancel: { probe.shouldCancel },
                using: { delegate, shouldStop in
                    delegate.didStartReading(withPointCount: 2)
                    delegate.didRead(points: [replacementPoint])
                    probe.didDeliverPoint()
                    if shouldStop() {
                        delegate.didFailReading(withError: CancellationError())
                        return
                    }
                    XCTFail("The injected reader did not observe cancellation after its first point.")
                    delegate.didRead(points: [replacementPoint])
                    delegate.didFinishReading()
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(probe.deliveredPointCount, 1)

        let after = try snapshot(renderer: renderer, direction: direction)
        XCTAssertEqual(after, before)
    }

    func testCapturedSHGenerationRendersCoherentlyAfterRGBPublication() throws {
        let renderer = try loadedDirectionalRenderer()
        let direction = simd_normalize(SIMD3<Float>(0.3, 0.5, 0.8))
        let view = viewMatrix(cameraPosition: -3 * direction)
        let expected = try renderCenterPixel(renderer: renderer, viewMatrix: view)
        let capturedScene = try XCTUnwrap(renderer.captureRenderScene())

        renderer.reset()
        try renderer.add(makePoint(color: .linearUInt8(224, 64, 16)))

        let capturedResult = try renderCenterPixel(
            renderer: renderer,
            viewMatrix: view,
            capturedScene: capturedScene
        )
        let currentResult = try renderCenterPixel(renderer: renderer, viewMatrix: view)
        assertEqual(capturedResult, expected, accuracy: 0.002)
        XCTAssertNotEqual(capturedResult, currentResult)
    }

    func testResetClearsSHStateAndAllowsAnRGBScene() throws {
        let renderer = try loadedDirectionalRenderer()

        renderer.reset()

        XCTAssertEqual(renderer.splatCount, 0)
        XCTAssertEqual(renderer.orderBuffer.count, 0)
        XCTAssertNil(renderer.sphericalHarmonicCoefficientBuffer)
        XCTAssertEqual(renderer.sphericalHarmonicDegree, .sh0)

        try renderer.add(makePoint(color: .linearUInt8(64, 128, 224)))

        XCTAssertEqual(renderer.splatCount, 1)
        XCTAssertNil(renderer.sphericalHarmonicCoefficientBuffer)
        XCTAssertEqual(renderer.sphericalHarmonicDegree, .sh0)
        let actual = try renderCenterPixel(renderer: renderer, direction: SIMD3<Float>(0, 0, 1))
        let expected = SIMD3<Float>(64, 128, 224) / 255
        assertEqual(actual, expected, accuracy: 0.002)
    }

    func testIncrementalAddRejectsMixedColorEncodingsWithoutMutation() throws {
        let rgbRenderer = try makeRenderer()
        try rgbRenderer.add(makePoint(color: .linearUInt8(64, 128, 224)))
        let rgbSplatBuffer = ObjectIdentifier(rgbRenderer.splatBuffer.buffer as AnyObject)
        let rgbOrderBuffer = ObjectIdentifier(rgbRenderer.orderBuffer.buffer as AnyObject)
        let rgbColor = rgbRenderer.splatBuffer.values[0].color

        XCTAssertThrowsError(try rgbRenderer.add(makePoint(color: .sphericalHarmonic(
            0.1,
            -0.05,
            0.02,
            Array(repeating: 0, count: 45)
        ))))

        XCTAssertEqual(rgbRenderer.splatCount, 1)
        XCTAssertEqual(ObjectIdentifier(rgbRenderer.splatBuffer.buffer as AnyObject), rgbSplatBuffer)
        XCTAssertEqual(ObjectIdentifier(rgbRenderer.orderBuffer.buffer as AnyObject), rgbOrderBuffer)
        XCTAssertNil(rgbRenderer.sphericalHarmonicCoefficientBuffer)
        XCTAssertEqual(rgbRenderer.sphericalHarmonicDegree, .sh0)
        XCTAssertEqual(rgbRenderer.splatBuffer.values[0].color.r, rgbColor.r)
        XCTAssertEqual(rgbRenderer.splatBuffer.values[0].color.g, rgbColor.g)
        XCTAssertEqual(rgbRenderer.splatBuffer.values[0].color.b, rgbColor.b)

        let shRenderer = try loadedDirectionalRenderer()
        let shSplatBuffer = ObjectIdentifier(shRenderer.splatBuffer.buffer as AnyObject)
        let shOrderBuffer = ObjectIdentifier(shRenderer.orderBuffer.buffer as AnyObject)
        let shBuffer = try XCTUnwrap(shRenderer.sphericalHarmonicCoefficientBuffer)
        let shCoefficientBuffer = ObjectIdentifier(shBuffer.buffer as AnyObject)

        XCTAssertThrowsError(try shRenderer.add(makePoint(color: .linearUInt8(64, 128, 224))))

        XCTAssertEqual(shRenderer.splatCount, 1)
        XCTAssertEqual(ObjectIdentifier(shRenderer.splatBuffer.buffer as AnyObject), shSplatBuffer)
        XCTAssertEqual(ObjectIdentifier(shRenderer.orderBuffer.buffer as AnyObject), shOrderBuffer)
        XCTAssertEqual(
            ObjectIdentifier(try XCTUnwrap(shRenderer.sphericalHarmonicCoefficientBuffer).buffer as AnyObject),
            shCoefficientBuffer
        )
        XCTAssertEqual(shRenderer.sphericalHarmonicDegree, .sh3)
    }

    func testEnsureAdditionalCapacityReservesFullSHPayload() throws {
        let renderer = try loadedDirectionalRenderer()

        try renderer.ensureAdditionalCapacity(99)

        XCTAssertGreaterThanOrEqual(renderer.splatBuffer.capacity, 100)
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(renderer.sphericalHarmonicCoefficientBuffer).capacity,
            100 * SplatRenderer.SHDegree.payloadCount
        )
        XCTAssertEqual(renderer.splatCount, 1)
        XCTAssertEqual(renderer.sphericalHarmonicCoefficientBuffer?.count, 16)
    }

    func testAmplifiedViewportsUseTheirOwnCameraPositions() throws {
        var coefficients = Array(repeating: SIMD3<Float>.zero, count: 15)
        coefficients[1].x = 0.5
        let rawDC = SIMD3<Float>.zero
        let url = try makeSH3PLY(rawDC: rawDC, coefficients: coefficients)
        let renderer = try makeRenderer(maxViewCount: 2)
        try renderer.readPLY(from: url)
        let directions = [SIMD3<Float>(0, 0, 1), SIMD3<Float>(0, 0, -1)]
        let views = directions.map { viewMatrix(cameraPosition: -3 * $0) }

        let actual = try renderAmplifiedCenterPixels(renderer: renderer, viewMatrices: views)

        XCTAssertNotEqual(actual[0], actual[1])
        for index in directions.indices {
            assertEqual(
                actual[index],
                evaluate(rawDC: rawDC, coefficients: coefficients, direction: directions[index]),
                accuracy: 0.002
            )
        }
    }

    func testFinalViewTransformKeepsCameraInOriginalSplatCoordinates() throws {
        var coefficients = Array(repeating: SIMD3<Float>.zero, count: 15)
        coefficients[2].y = 0.45
        let rawDC = SIMD3<Float>(0.05, 0.05, 0.05)
        let url = try makeSH3PLY(rawDC: rawDC, coefficients: coefficients)
        let renderer = try makeRenderer()
        try renderer.readPLY(from: url)
        let cameraView = viewMatrix(cameraPosition: SIMD3<Float>(0, 0, 3))
        let modelTransform = simd_float4x4(
            simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        )
        let finalView = cameraView * modelTransform
        let cameraHomogeneous = finalView.inverse * SIMD4<Float>(0, 0, 0, 1)
        let cameraInSplatCoordinates = SIMD3<Float>(
            cameraHomogeneous.x,
            cameraHomogeneous.y,
            cameraHomogeneous.z
        )
        let direction = simd_normalize(-cameraInSplatCoordinates)

        let actual = try renderCenterPixel(renderer: renderer, viewMatrix: finalView)
        let expected = evaluate(rawDC: rawDC, coefficients: coefficients, direction: direction)

        assertEqual(actual, expected, accuracy: 0.002)
    }

    func testSwiftShaderABIContract() {
        XCTAssertEqual(MemoryLayout<SplatRenderer.Uniforms>.offset(of: \.projectionMatrix), 0)
        XCTAssertEqual(MemoryLayout<SplatRenderer.Uniforms>.offset(of: \.viewMatrix), 64)
        XCTAssertEqual(MemoryLayout<SplatRenderer.Uniforms>.offset(of: \.cameraWorldPosition), 128)
        XCTAssertEqual(MemoryLayout<SplatRenderer.Uniforms>.offset(of: \.sphericalHarmonicDegree), 140)
        XCTAssertEqual(MemoryLayout<SplatRenderer.Uniforms>.offset(of: \.screenSize), 144)
        XCTAssertEqual(MemoryLayout<SplatRenderer.Uniforms>.size, 152)
        XCTAssertEqual(MemoryLayout<SplatRenderer.Uniforms>.stride, 160)
        XCTAssertEqual(MemoryLayout<SplatRenderer.UniformsArray>.size, 312)
        XCTAssertEqual(MemoryLayout<SplatRenderer.UniformsArray>.stride, 320)
        XCTAssertEqual(SplatRenderer.UniformsArray.alignedSize, 512)
        XCTAssertEqual(SplatRenderer.BufferIndex.uniforms.rawValue, 0)
        XCTAssertEqual(SplatRenderer.BufferIndex.splat.rawValue, 1)
        XCTAssertEqual(SplatRenderer.BufferIndex.order.rawValue, 2)
        XCTAssertEqual(SplatRenderer.BufferIndex.sphericalHarmonic.rawValue, 3)
    }

    func testRepeatedSHRenderingIsByteDeterministic() throws {
        let renderer = try loadedDirectionalRenderer()
        let view = viewMatrix(cameraPosition: SIMD3<Float>(-1.2, -2.0, -2.4))

        let first = try renderImage(renderer: renderer, viewMatrix: view)
        let second = try renderImage(renderer: renderer, viewMatrix: view)

        XCTAssertEqual(first, second)
    }

    // An opaque splat covering the sampled pixel must come back out as the code value
    // that went in. Any conversion reintroduced on either the encode or the attachment
    // side breaks this, which is what made the viewer diverge from the trainer.
    func testSH0RGBRoundTripsUInt8CodeValuesExactly() throws {
        let renderer = try makeRenderer(colorFormat: .bgra8Unorm)
        var maximumDifference = 0

        for value in UInt8.min...UInt8.max {
            renderer.reset()
            try renderer.add(makePoint(color: .linearUInt8(value, value, value)))
            let actual = try renderBGRA8CenterPixel(renderer: renderer)
            for channel in 0..<3 {
                maximumDifference = max(
                    maximumDifference,
                    abs(Int(actual[channel]) - Int(value))
                )
            }
        }

        XCTAssertLessThanOrEqual(maximumDifference, 1)
    }

    private func loadedDirectionalRenderer() throws -> SplatRenderer {
        let coefficients = (0..<15).map { index in
            let n = Float(index + 1)
            return SIMD3<Float>(0.008 * n, -0.004 * n, 0.006 * n)
        }
        let url = try makeSH3PLY(
            rawDC: SIMD3<Float>(0.1, -0.05, 0.02),
            coefficients: coefficients
        )
        let renderer = try makeRenderer()
        try renderer.readPLY(from: url)
        return renderer
    }

    private func snapshot(
        renderer: SplatRenderer,
        direction: SIMD3<Float>
    ) throws -> SHSceneSnapshot {
        let coefficients = try XCTUnwrap(renderer.sphericalHarmonicCoefficientBuffer)
        let coefficientData = Data(
            bytes: coefficients.values,
            count: coefficients.count * MemoryLayout<SplatRenderer.PackedHalf3>.stride
        )
        return SHSceneSnapshot(
            splatBuffer: ObjectIdentifier(renderer.splatBuffer.buffer as AnyObject),
            orderBuffer: ObjectIdentifier(renderer.orderBuffer.buffer as AnyObject),
            coefficientBuffer: ObjectIdentifier(coefficients.buffer as AnyObject),
            coefficientCount: coefficients.count,
            coefficientData: coefficientData,
            degreeRawValue: renderer.sphericalHarmonicDegree.rawValue,
            splatCount: renderer.splatCount,
            renderedPixel: try renderCenterPixel(renderer: renderer, direction: direction)
        )
    }

    private func makeRenderer(
        maxViewCount: Int = 1,
        colorFormat: MTLPixelFormat = .rgba16Float
    ) throws -> SplatRenderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }
        return try SplatRenderer(
            device: device,
            colorFormat: colorFormat,
            depthFormat: .invalid,
            stencilFormat: .invalid,
            sampleCount: 1,
            maxViewCount: maxViewCount,
            maxSimultaneousRenders: 1,
            sortOrdering: .cameraForwardDepth
        )
    }

    private func makePoint(color: SplatScenePoint.Color) -> SplatScenePoint {
        SplatScenePoint(
            position: .zero,
            normal: .zero,
            color: color,
            opacity: 20,
            scale: .zero,
            rotation: simd_quatf(real: 1, imag: .zero)
        )
    }

    /// Splat storage holds the sRGB code values the trainer fitted, quantized to half.
    private func assertStoredColor(
        _ stored: SplatRenderer.PackedRGBHalf4,
        expectedSRGB: SIMD3<Float>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = SIMD3<Float>(
            Float(Float16(expectedSRGB.x)),
            Float(Float16(expectedSRGB.y)),
            Float(Float16(expectedSRGB.z))
        )
        let actual = SIMD3<Float>(Float(stored.r), Float(stored.g), Float(stored.b))
        assertEqual(actual, expected, accuracy: 0, file: file, line: line)
    }

    private func renderCenterPixel(
        renderer: SplatRenderer,
        direction: SIMD3<Float>
    ) throws -> SIMD3<Float> {
        let direction = simd_normalize(direction)
        let cameraPosition = -3 * direction
        return try renderCenterPixel(
            renderer: renderer,
            viewMatrix: viewMatrix(cameraPosition: cameraPosition)
        )
    }

    private func renderCenterPixel(
        renderer: SplatRenderer,
        viewMatrix: simd_float4x4,
        capturedScene: SplatRenderer.RenderSceneSnapshot? = nil
    ) throws -> SIMD3<Float> {
        centerPixel(
            from: try renderImage(
                renderer: renderer,
                viewMatrix: viewMatrix,
                capturedScene: capturedScene
            ),
            width: 65
        )
    }

    private func renderImage(
        renderer: SplatRenderer,
        viewMatrix: simd_float4x4,
        capturedScene: SplatRenderer.RenderSceneSnapshot? = nil
    ) throws -> [UInt16] {
        let descriptor = SplatRenderer.CameraDescriptor(
            projectionMatrix: perspectiveProjection,
            viewMatrix: viewMatrix,
            screenSize: SIMD2<Int>(65, 65)
        )
        guard let queue = renderer.splatBuffer.device.makeCommandQueue() else {
            throw XCTSkip("Metal command queues are unavailable")
        }
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: 65,
            height: 65,
            mipmapped: false
        )
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = [.renderTarget]
        let texture = try XCTUnwrap(renderer.splatBuffer.device.makeTexture(descriptor: textureDescriptor))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        let encoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        if let capturedScene {
            renderer.render(
                viewportCameras: [descriptor],
                capturedScene: capturedScene,
                to: encoder
            )
        } else {
            renderer.render(viewportCameras: [descriptor], to: encoder)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)

        var image = [UInt16](repeating: 0, count: 65 * 65 * 4)
        image.withUnsafeMutableBytes { bytes in
            texture.getBytes(
                bytes.baseAddress!,
                bytesPerRow: 65 * 8,
                from: MTLRegionMake2D(0, 0, 65, 65),
                mipmapLevel: 0
            )
        }
        return image
    }

    private func renderBGRA8CenterPixel(renderer: SplatRenderer) throws -> [UInt8] {
        let width = 65
        let descriptor = SplatRenderer.CameraDescriptor(
            projectionMatrix: perspectiveProjection,
            viewMatrix: viewMatrix(cameraPosition: SIMD3<Float>(0, 0, 3)),
            screenSize: SIMD2<Int>(repeating: width)
        )
        let device = renderer.splatBuffer.device
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: width,
            mipmapped: false
        )
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = [.renderTarget]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        let renderEncoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        renderer.render(viewportCameras: [descriptor], to: renderEncoder)
        renderEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)

        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            texture.getBytes(
                bytes.baseAddress!,
                bytesPerRow: 4,
                from: MTLRegionMake2D(width / 2, width / 2, 1, 1),
                mipmapLevel: 0
            )
        }
        return pixel
    }

    private func centerPixel(from image: [UInt16], width: Int, xOffset: Int = 0) -> SIMD3<Float> {
        let offset = (32 * width + xOffset + 32) * 4
        return SIMD3<Float>(
            Float(Float16(bitPattern: image[offset])),
            Float(Float16(bitPattern: image[offset + 1])),
            Float(Float16(bitPattern: image[offset + 2]))
        )
    }

    private func renderAmplifiedCenterPixels(
        renderer: SplatRenderer,
        viewMatrices: [simd_float4x4]
    ) throws -> [SIMD3<Float>] {
        precondition(viewMatrices.count == 2)
        let descriptors = viewMatrices.map {
            SplatRenderer.CameraDescriptor(
                projectionMatrix: perspectiveProjection,
                viewMatrix: $0,
                screenSize: SIMD2<Int>(65, 65)
            )
        }
        let device = renderer.splatBuffer.device
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: 130,
            height: 65,
            mipmapped: false
        )
        textureDescriptor.storageMode = .shared
        textureDescriptor.usage = [.renderTarget]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        let encoder = try XCTUnwrap(commandBuffer.makeRenderCommandEncoder(descriptor: pass))
        encoder.setViewports([
            MTLViewport(originX: 0, originY: 0, width: 65, height: 65, znear: 0, zfar: 1),
            MTLViewport(originX: 65, originY: 0, width: 65, height: 65, znear: 0, zfar: 1),
        ])
        var mappings = [
            MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: 0, renderTargetArrayIndexOffset: 0),
            MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: 1, renderTargetArrayIndexOffset: 0),
        ]
        encoder.setVertexAmplificationCount(2, viewMappings: &mappings)
        renderer.render(viewportCameras: descriptors, to: encoder)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        XCTAssertNil(commandBuffer.error)

        var image = [UInt16](repeating: 0, count: 130 * 65 * 4)
        image.withUnsafeMutableBytes { bytes in
            texture.getBytes(
                bytes.baseAddress!,
                bytesPerRow: 130 * 8,
                from: MTLRegionMake2D(0, 0, 130, 65),
                mipmapLevel: 0
            )
        }
        return [
            centerPixel(from: image, width: 130),
            centerPixel(from: image, width: 130, xOffset: 65),
        ]
    }

    private var perspectiveProjection: simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(1.732_050_8, 0, 0, 0),
            SIMD4<Float>(0, 1.732_050_8, 0, 0),
            SIMD4<Float>(0, 0, -1.002_002, -1),
            SIMD4<Float>(0, 0, -0.200_200_2, 0)
        ))
    }

    private func viewMatrix(cameraPosition: SIMD3<Float>) -> simd_float4x4 {
        let forward = simd_normalize(-cameraPosition)
        let referenceUp = abs(simd_dot(forward, SIMD3<Float>(0, 1, 0))) > 0.99
            ? SIMD3<Float>(0, 0, 1)
            : SIMD3<Float>(0, 1, 0)
        let right = simd_normalize(simd_cross(forward, referenceUp))
        let up = simd_cross(right, forward)
        let back = -forward
        let translation = SIMD3<Float>(
            -simd_dot(right, cameraPosition),
            -simd_dot(up, cameraPosition),
            -simd_dot(back, cameraPosition)
        )
        return simd_float4x4(columns: (
            SIMD4<Float>(right.x, up.x, back.x, 0),
            SIMD4<Float>(right.y, up.y, back.y, 0),
            SIMD4<Float>(right.z, up.z, back.z, 0),
            SIMD4<Float>(translation, 1)
        ))
    }

    private func makeSH3PLY(
        rawDC: SIMD3<Float>,
        coefficients: [SIMD3<Float>],
        position: SIMD3<Float> = .zero,
        omitFinalValue: Bool = false,
        validPointBeforeMalformedPoint: Bool = false
    ) throws -> URL {
        precondition(coefficients.count == 15)
        let restProperties = (0..<45).map { "property float f_rest_\($0)" }.joined(separator: "\n")
        let channelMajor = coefficients.map(\.x) + coefficients.map(\.y) + coefficients.map(\.z)
        let values = ([rawDC.x, rawDC.y, rawDC.z] + channelMajor)
            .map { String($0) }
            .joined(separator: " ")
        let validTrailingValues = "0 0 0 20 1 0 0 0"
        let trailingValues = omitFinalValue ? "0 0 0 20 1 0 0" : validTrailingValues
        let point = "\(position.x) \(position.y) \(position.z) \(values) \(trailingValues)"
        let points: String
        if validPointBeforeMalformedPoint {
            points = "\(position.x) \(position.y) \(position.z) \(values) \(validTrailingValues)\n\(point)"
        } else {
            points = point
        }
        let pointCount = validPointBeforeMalformedPoint ? 2 : 1
        let contents = """
        ply
        format ascii 1.0
        element vertex \(pointCount)
        property float x
        property float y
        property float z
        property float f_dc_0
        property float f_dc_1
        property float f_dc_2
        \(restProperties)
        property float scale_0
        property float scale_1
        property float scale_2
        property float opacity
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        \(points)
        """
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("sh3.ply")
        try contents.write(to: url, atomically: true, encoding: String.Encoding.utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return url
    }

    private func evaluate(
        rawDC: SIMD3<Float>,
        coefficients: [SIMD3<Float>],
        direction: SIMD3<Float>
    ) -> SIMD3<Float> {
        let dc = SIMD3<Float>(
            Float(Float16(rawDC.x)),
            Float(Float16(rawDC.y)),
            Float(Float16(rawDC.z))
        )
        let sh = coefficients.map { coefficient in
            SIMD3<Float>(
                Float(Float16(coefficient.x)),
                Float(Float16(coefficient.y)),
                Float(Float16(coefficient.z))
            )
        }
        let x = direction.x
        let y = direction.y
        let z = direction.z
        let xx = x * x
        let yy = y * y
        let zz = z * z
        let xxPlusYy = xx + yy
        let fourZZMinusXXYY = 4 * zz - xxPlusYy
        let degreeThreeCenter = 2 * zz - 3 * xxPlusYy
        var result = shC0 * dc
        result += -0.4886025119029199 * y * sh[0]
        result += 0.4886025119029199 * z * sh[1]
        result += -0.4886025119029199 * x * sh[2]
        result += 1.0925484305920792 * x * y * sh[3]
        result += -1.0925484305920792 * y * z * sh[4]
        result += 0.31539156525252005 * (2 * zz - xxPlusYy) * sh[5]
        result += -1.0925484305920792 * x * z * sh[6]
        result += 0.5462742152960396 * (xx - yy) * sh[7]
        result += -0.5900435899266435 * y * (3 * xx - yy) * sh[8]
        result += 2.890611442640554 * x * y * z * sh[9]
        result += -0.4570457994644658 * y * fourZZMinusXXYY * sh[10]
        result += 0.3731763325901154 * z * degreeThreeCenter * sh[11]
        result += -0.4570457994644658 * x * fourZZMinusXXYY * sh[12]
        result += 1.445305721320277 * z * (xx - yy) * sh[13]
        result += -0.5900435899266435 * x * (xx - 3 * yy) * sh[14]
        return simd_max(result + SIMD3<Float>(repeating: 0.5), .zero)
    }

    private func assertEqual(
        _ actual: SIMD3<Float>,
        _ expected: SIMD3<Float>,
        accuracy: Float,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, message, file: file, line: line)
        XCTAssertEqual(actual.z, expected.z, accuracy: accuracy, message, file: file, line: line)
    }
}

private struct SHSceneSnapshot: Equatable {
    let splatBuffer: ObjectIdentifier
    let orderBuffer: ObjectIdentifier
    let coefficientBuffer: ObjectIdentifier
    let coefficientCount: Int
    let coefficientData: Data
    let degreeRawValue: UInt32
    let splatCount: Int
    let renderedPixel: SIMD3<Float>
}

private final class SHCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var deliveredPoints = 0

    var deliveredPointCount: Int {
        lock.withLock { deliveredPoints }
    }

    var shouldCancel: Bool {
        lock.withLock { deliveredPoints > 0 }
    }

    func didDeliverPoint() {
        lock.withLock { deliveredPoints += 1 }
    }
}
