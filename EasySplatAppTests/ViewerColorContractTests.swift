import Metal
import MetalKit
import XCTest
@testable import EasySplatApp

/// The splat buffer holds sRGB code values because that is the space msplat fits and
/// composites in. Nothing else pinned the drawable against that choice, so the two
/// halves could drift apart silently: an sRGB attachment linearises the destination
/// before every blend, which is a different compositing operator than the one the
/// model was trained under, and it shows up only at partial alpha.
@MainActor
final class ViewerColorContractTests: XCTestCase {
    func testDrawableDoesNotLineariseSplatColorsForBlending() throws {
        let view = try makeConfiguredView()

        XCTAssertFalse(
            Self.srgbFormats.contains(view.colorPixelFormat),
            "An sRGB drawable blends in linear light and diverges from the trainer."
        )
    }

    func testDrawableDeclaresAColorSpaceSoWideGamutDisplaysMatch() throws {
        let view = try makeConfiguredView()

        XCTAssertNotNil(
            view.colorspace,
            "A nil colour space means no colour matching, so sRGB values reach a "
                + "Display P3 panel unconverted."
        )
    }

    // The renderer clears to alpha 0 and emits premultiplied alpha, so what a partially
    // covered pixel looks like depends on how the layer is composited. An opaque layer
    // presents the premultiplied RGB as-is, which is the same thing as compositing over
    // black - and black is exactly what the trainer composites over
    // (`background[3] = {0, 0, 0}` in msplat.cpp) and what the offscreen benchmark
    // evaluates against. Making the layer non-opaque would blend sparse regions into the
    // SwiftUI background instead and put the live view out of step with both.
    func testDrawableCompositesOverBlackLikeTheTrainer() throws {
        let view = try makeConfiguredView()

        XCTAssertEqual(view.layer?.isOpaque, true)
        XCTAssertEqual(view.clearColor.red, 0)
        XCTAssertEqual(view.clearColor.green, 0)
        XCTAssertEqual(view.clearColor.blue, 0)
        XCTAssertEqual(view.clearColor.alpha, 0)
    }

    private static let srgbFormats: Set<MTLPixelFormat> = [
        .bgra8Unorm_srgb, .rgba8Unorm_srgb, .bgr10_xr_srgb, .bgra10_xr_srgb
    ]

    private func makeConfiguredView() throws -> MTKView {
        let device = try XCTUnwrap(
            MTLCreateSystemDefaultDevice(),
            "This test needs a Metal device."
        )
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
        XCTAssertNotNil(
            MetalKitSceneRenderer(view),
            "The renderer configures the drawable in its initialiser."
        )
        return view
    }
}
