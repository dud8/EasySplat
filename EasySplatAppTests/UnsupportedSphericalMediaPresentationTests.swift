import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatApp
@testable import EasySplatCore

@MainActor
final class UnsupportedSphericalMediaPresentationTests: XCTestCase {
    func testUnsupportedSphericalPresentationUsesProductCopyAndBoundedTechnicalDetail() {
        let presentation = AppModel.unsupportedSphericalMediaPresentation(
            .init(tag: .appleImmersive)
        )

        XCTAssertEqual(
            presentation.title,
            "This appears to be 180°/360° panoramic media. EasySplat does not yet unwrap spherical captures. Export ordinary perspective views and try again."
        )
        XCTAssertEqual(
            presentation.details,
            "Detected standardized projection tag: apple-immersive."
        )
        XCTAssertFalse(presentation.details.contains("/"))
        XCTAssertFalse(presentation.details.lowercased().contains("backend"))
    }

    func testMixedInputRejectsTaggedStillBeforeToolsOrProjectCreation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let photo = photos.appendingPathComponent("private-owner.jpg")
        try writeTaggedPanoramaJPEG(at: photo)
        let video = root.appendingPathComponent("ordinary.mov")
        try Data("video".utf8).write(to: video)
        let tools = CapabilityRecordingToolchainManager()
        var pipelineFactoryCount = 0
        let videoPreflight = VideoInputPreflight(
            limits: .init(
                maximumVideoCount: 1,
                maximumTotalBytes: 1_024,
                minimumFreeSpaceReserveBytes: 0,
                maximumConcurrentDecoders: 1
            ),
            availableCapacity: { _ in Int64.max },
            analyze: { _, _ in
                VideoInputAnalysisEvidence(
                    trackID: 1,
                    pixelWidth: 64,
                    pixelHeight: 48,
                    durationSeconds: 1,
                    nominalFrameRate: 30,
                    isHDR: false,
                    decodedFrameCount: 1,
                    preferredTransform: .identity
                )
            },
            projectionProbe: { _ in nil }
        )
        let model = AppModel(
            toolchainManager: tools,
            projectBaseURL: root,
            videoInputPreflight: videoPreflight
        ) { projectURL, config in
            pipelineFactoryCount += 1
            return MockPipelineRunner(projectURL: projectURL, config: config)
        }

        await model.startProject(
            input: .mixed(videos: [video.path], photosFolder: photos.path),
            title: "Panorama"
        )

        XCTAssertNil(tools.lastRequest)
        XCTAssertEqual(pipelineFactoryCount, 0)
        XCTAssertNil(model.currentProjectURL)
        XCTAssertEqual(
            model.lastError,
            "This appears to be 180°/360° panoramic media. EasySplat does not yet unwrap spherical captures. Export ordinary perspective views and try again."
        )
        XCTAssertEqual(
            model.errorDetails,
            "Detected standardized projection tag: equirectangular-360."
        )
        XCTAssertFalse(model.errorDetails?.contains("private-owner") == true)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains { $0.hasSuffix(".easysplatproj") }
        )
    }
}

private func writeTaggedPanoramaJPEG(at url: URL) throws {
    let context = try XCTUnwrap(CGContext(
        data: nil,
        width: 200,
        height: 100,
        bitsPerComponent: 8,
        bytesPerRow: 800,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ))
    let metadata = CGImageMetadataCreateMutable()
    var error: Unmanaged<CFError>?
    XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(
        metadata,
        "http://ns.google.com/photos/1.0/panorama/" as CFString,
        "GPano" as CFString,
        &error
    ))
    XCTAssertNil(error)
    XCTAssertTrue(CGImageMetadataSetValueWithPath(
        metadata,
        nil,
        "GPano:ProjectionType" as CFString,
        "equirectangular" as CFString
    ))
    XCTAssertTrue(CGImageMetadataSetValueWithPath(
        metadata,
        nil,
        "GPano:UsePanoramaViewer" as CFString,
        "True" as CFString
    ))
    CGImageDestinationAddImageAndMetadata(
        destination,
        try XCTUnwrap(context.makeImage()),
        metadata,
        nil
    )
    XCTAssertTrue(CGImageDestinationFinalize(destination))
}
