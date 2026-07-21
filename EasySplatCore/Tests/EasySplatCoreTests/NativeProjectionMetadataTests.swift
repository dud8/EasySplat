import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatCore

final class NativeProjectionMetadataTests: XCTestCase {
    func testProjectionProbeSourceDoesNotReferenceMacOS26OnlySDKDeclarations() throws {
        let easySplatCore = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: easySplatCore.appendingPathComponent(
                "Sources/EasySplatCore/Project/NativeProjectionMetadata.swift"
            ),
            encoding: .utf8
        )
        for forbiddenDeclaration in [
            "AVURLAssetShouldParseExternalSphericalTagsKey",
            "kCMFormatDescriptionProjectionKind_AppleImmersiveVideo",
            "kCMFormatDescriptionProjectionKind_ParametricImmersive",
        ] {
            XCTAssertFalse(
                source.contains(forbiddenDeclaration),
                "The macOS 15 / Xcode 16.4 lane cannot compile \(forbiddenDeclaration)."
            )
        }
    }

    func testStandardizedVideoProjectionValuesMapToTypedTags() {
        XCTAssertEqual(
            NativeProjectionMetadataProbe.tag(fromVideoProjectionKindValues: [
                "Equirectangular",
            ]),
            .equirectangular360
        )
        XCTAssertEqual(
            NativeProjectionMetadataProbe.tag(fromVideoProjectionKindValues: [
                "HalfEquirectangular",
            ]),
            .halfEquirectangular180
        )
        XCTAssertEqual(
            NativeProjectionMetadataProbe.tag(fromVideoProjectionKindValues: [
                "AppleImmersiveVideo",
            ]),
            .appleImmersive
        )
        XCTAssertEqual(
            NativeProjectionMetadataProbe.tag(fromVideoProjectionKindValues: [
                "ParametricImmersive",
            ]),
            .parametricImmersive
        )
    }

    func testRecognizedProjectionIsNotCancelledByRectilinearOrUnknownDescriptions() {
        XCTAssertEqual(NativeProjectionMetadataProbe.tag(fromVideoProjectionKindValues: [
            "Equirectangular",
            "Rectilinear",
            "future-projection-kind",
        ]), .equirectangular360)
    }

    func testConflictingRecognizedVideoProjectionValuesRemainAmbiguous() {
        XCTAssertNil(NativeProjectionMetadataProbe.tag(fromVideoProjectionKindValues: [
            "Equirectangular",
            "HalfEquirectangular",
        ]))
        XCTAssertNil(NativeProjectionMetadataProbe.tag(fromVideoProjectionKindValues: [
            "future-projection-kind",
        ]))
    }

    func testTaggedEquirectangularStillIsDetectedAs360() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("panorama.jpg")
        try writeJPEG(
            at: image,
            width: 200,
            height: 100,
            gpanoProjectionType: "equirectangular",
            usePanoramaViewer: "True"
        )

        XCTAssertEqual(
            NativeProjectionMetadataProbe.tag(inImageAt: image),
            .equirectangular360
        )
    }

    func testGPanoNamespaceIsRecognizedWithAnArbitraryPrefix() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("custom-prefix.jpg")
        try writeJPEG(
            at: image,
            width: 200,
            height: 100,
            gpanoPrefix: "pano",
            gpanoProjectionType: "equirectangular"
        )

        XCTAssertEqual(
            NativeProjectionMetadataProbe.tag(inImageAt: image),
            .equirectangular360
        )
    }

    func testUntaggedTwoToOneStillIsNotClassifiedAsSpherical() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("wide-perspective.jpg")
        try writeJPEG(at: image, width: 200, height: 100)

        XCTAssertNil(NativeProjectionMetadataProbe.tag(inImageAt: image))
    }

    func testUnknownGPanoMetadataRemainsAmbiguousButViewerPreferenceCannotVetoProjection() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let unknown = root.appendingPathComponent("unknown.jpg")
        let conflicting = root.appendingPathComponent("conflicting.jpg")
        try writeJPEG(
            at: unknown,
            width: 200,
            height: 100,
            gpanoProjectionType: "cylindrical",
            usePanoramaViewer: "True"
        )
        try writeJPEG(
            at: conflicting,
            width: 200,
            height: 100,
            gpanoProjectionType: "equirectangular",
            usePanoramaViewer: "False"
        )

        XCTAssertNil(NativeProjectionMetadataProbe.tag(inImageAt: unknown))
        XCTAssertEqual(
            NativeProjectionMetadataProbe.tag(inImageAt: conflicting),
            .equirectangular360
        )
    }

    func testStandardizedISOBaseMediaMetadataDetectsFullAndHalfEquirectangular() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let full = root.appendingPathComponent("full.mp4")
        let half = root.appendingPathComponent("half.mp4")
        try sphericalV1Fixture(trackID: 7).write(to: full)
        try sphericalV2Fixture(trackID: 9, halfHorizontalCoverage: true).write(to: half)

        XCTAssertEqual(
            try NativeProjectionMetadataProbe.tag(
                inISOBaseMediaAt: full,
                selectedTrackID: 7
            ),
            .equirectangular360
        )
        XCTAssertEqual(
            try NativeProjectionMetadataProbe.tag(
                inISOBaseMediaAt: half,
                selectedTrackID: 9
            ),
            .halfEquirectangular180
        )
    }

    func testISOBaseMediaMetadataIsBoundToTheSelectedTrack() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("two-tracks.mp4")
        let data = isoBox("moov", payload:
            isoBox("trak", payload: trackHeader(trackID: 1))
                + isoBox("trak", payload:
                    trackHeader(trackID: 2) + sphericalV1UUIDBox()
                )
        )
        try data.write(to: movie)

        XCTAssertNil(try NativeProjectionMetadataProbe.tag(
            inISOBaseMediaAt: movie,
            selectedTrackID: 1
        ))
        XCTAssertEqual(
            try NativeProjectionMetadataProbe.tag(
                inISOBaseMediaAt: movie,
                selectedTrackID: 2
            ),
            .equirectangular360
        )
    }

    func testISOBaseMediaParserIgnoresPayloadLookalikesOutsideTrackMetadata() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("lookalike.mp4")
        let lookalike = sphericalV1UUID + Data(sphericalV1XML.utf8)
        try (isoBox("mdat", payload: lookalike)
            + isoBox("moov", payload: isoBox("trak", payload: trackHeader(trackID: 3))))
            .write(to: movie)

        XCTAssertNil(try NativeProjectionMetadataProbe.tag(
            inISOBaseMediaAt: movie,
            selectedTrackID: 3
        ))
    }

    func testISOBaseMediaParserRejectsMalformedOversizedAndDeepMetadata() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let malformed = root.appendingPathComponent("malformed.mp4")
        let oversized = root.appendingPathComponent("oversized.mp4")
        let deep = root.appendingPathComponent("deep.mp4")
        try (bigEndian(UInt32(64)) + Data("moov".utf8) + Data([0])).write(to: malformed)
        try isoBox("moov", payload: isoBox("trak", payload:
            trackHeader(trackID: 4)
                + isoBox("uuid", payload: sphericalV1UUID + Data(repeating: 0x20, count: 300_000))
        )).write(to: oversized)
        var nested = sphericalV1UUIDBox()
        for _ in 0..<24 {
            nested = isoBox("meta", payload: Data([0, 0, 0, 0]) + nested)
        }
        try isoBox("moov", payload: isoBox("trak", payload:
            trackHeader(trackID: 5) + nested
        )).write(to: deep)

        XCTAssertThrowsError(try NativeProjectionMetadataProbe.tag(
            inISOBaseMediaAt: malformed,
            selectedTrackID: 4
        ))
        XCTAssertThrowsError(try NativeProjectionMetadataProbe.tag(
            inISOBaseMediaAt: oversized,
            selectedTrackID: 4
        ))
        XCTAssertThrowsError(try NativeProjectionMetadataProbe.tag(
            inISOBaseMediaAt: deep,
            selectedTrackID: 5
        ))
    }

    func testOrdinaryVideoInspectionUsesTheFrameExtractorPrimaryTrack() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("ordinary.mov")
        try await TestVideoBuilder.writeH264(
            to: movie,
            times: [0, 0.05, 0.1],
            levels: [32, 96, 160]
        )

        let frameSource = try await FrameExtractor().inspect(movie)
        let projection = try await NativeProjectionMetadataProbe.inspection(inVideoAt: movie)

        XCTAssertEqual(projection.primaryTrackID, frameSource.primaryTrack.trackID)
        XCTAssertNil(projection.tag)
    }

    func testVideoInspectionReadsExternalSphericalMetadataFromItsSelectedTrack() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let movie = root.appendingPathComponent("external-spherical.mov")
        try await TestVideoBuilder.writeH264(
            to: movie,
            times: [0, 0.05, 0.1],
            levels: [32, 96, 160]
        )
        try insertSphericalV1UUIDIntoFirstTrack(at: movie)

        let projection = try await NativeProjectionMetadataProbe.inspection(inVideoAt: movie)

        XCTAssertEqual(projection.tag, .equirectangular360)
    }

    func testPhotoAdmissionRejectsTaggedStillWithTypedIssue() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try writeJPEG(
            at: photos.appendingPathComponent("private-owner-name.jpg"),
            width: 200,
            height: 100,
            gpanoProjectionType: "equirectangular",
            usePanoramaViewer: "True"
        )

        do {
            _ = try await PhotoInputPreflight.prepare(
                folder: photos,
                stagingParent: root,
                photoSelection: .automatic,
                inputOrdering: .automatic,
                keyframeBudget: 1,
                requiredAtomicWorkspaceReserveBytes: 0,
                limits: .init(minimumFreeSpaceReserveBytes: 0),
                availableCapacity: { _ in Int64.max },
                progress: { _, _ in }
            )
            XCTFail("Tagged spherical stills must fail admission.")
        } catch let failure as PhotoInputPreflightFailure {
            XCTAssertEqual(
                failure.issue,
                .unsupportedSpherical(.init(tag: .equirectangular360))
            )
            XCTAssertFalse(String(describing: failure.issue).contains("private-owner-name"))
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(atPath: root.path)
                    .filter { $0.hasSuffix(".easysplatproj") },
                []
            )
        }
    }

    func testTaggedStillIsRejectedBeforeRawDevelopment() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try writeJPEG(
            at: photos.appendingPathComponent("panorama.dng"),
            width: 200,
            height: 100,
            gpanoProjectionType: "equirectangular",
            usePanoramaViewer: "True"
        )

        do {
            _ = try await PhotoInputPreflight.prepare(
                folder: photos,
                stagingParent: root,
                photoSelection: .automatic,
                inputOrdering: .automatic,
                keyframeBudget: 1,
                requiredAtomicWorkspaceReserveBytes: 0,
                limits: .init(minimumFreeSpaceReserveBytes: 0),
                availableCapacity: { _ in Int64.max },
                contentTypeResolver: { _ in UTType.rawImage.identifier },
                rawDecoder: RawDecoderThatMustNotRun(),
                progress: { _, _ in }
            )
            XCTFail("Tagged stills must be rejected before RAW decoding.")
        } catch let failure as PhotoInputPreflightFailure {
            XCTAssertEqual(
                failure.issue,
                .unsupportedSpherical(.init(tag: .equirectangular360))
            )
        }
    }

    func testPhotoAdmissionRevalidatesSourceBeforeActingOnPositiveProjectionTag() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let photo = photos.appendingPathComponent("changed.jpg")
        try writeJPEG(at: photo, width: 64, height: 48)

        do {
            _ = try await PhotoInputPreflight.prepare(
                folder: photos,
                stagingParent: root,
                photoSelection: .automatic,
                inputOrdering: .automatic,
                keyframeBudget: 1,
                requiredAtomicWorkspaceReserveBytes: 0,
                limits: .init(minimumFreeSpaceReserveBytes: 0),
                availableCapacity: { _ in Int64.max },
                projectionProbe: { _ in
                    try? FileManager.default.removeItem(at: photo)
                    try? Data("replacement".utf8).write(to: photo)
                    return .equirectangular360
                },
                progress: { _, _ in }
            )
            XCTFail("A changed source must not produce a projection verdict.")
        } catch let failure as PhotoInputPreflightFailure {
            guard case .sourceChanged = failure.issue else {
                return XCTFail("Expected sourceChanged, received \(failure.issue).")
            }
        }
    }

    func testVideoAdmissionRejectsInjectedHalfEquirectangularTag() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("private-client.mov")
        try Data("video".utf8).write(to: video)
        let preflight = VideoInputPreflight(
            limits: .init(
                maximumVideoCount: 1,
                maximumTotalBytes: 1_024,
                minimumFreeSpaceReserveBytes: 0,
                maximumConcurrentDecoders: 1
            ),
            availableCapacity: { _ in Int64.max },
            analyze: { _, _ in validVideoAnalysis() },
            projectionProbe: { _ in
                NativeVideoProjectionInspection(
                    primaryTrackID: 1,
                    tag: .halfEquirectangular180
                )
            }
        )

        do {
            _ = try await preflight.prepare(
                videoURLs: [video],
                stagingParent: root,
                requiredAtomicWorkspaceReserveBytes: 0,
                progress: { _, _ in }
            )
            XCTFail("Tagged spherical video must fail admission.")
        } catch let failure as VideoInputPreflightFailure {
            XCTAssertEqual(
                failure.rejectedVideos.map(\.issue),
                [.unsupportedSpherical(.init(tag: .halfEquirectangular180))]
            )
        }
    }

    func testUntaggedTwoToOneVideoContinuesThroughAdmission() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("wide.mov")
        try Data("video".utf8).write(to: video)
        let preflight = VideoInputPreflight(
            limits: .init(
                maximumVideoCount: 1,
                maximumTotalBytes: 1_024,
                minimumFreeSpaceReserveBytes: 0,
                maximumConcurrentDecoders: 1
            ),
            availableCapacity: { _ in Int64.max },
            analyze: { _, _ in
                validVideoAnalysis(pixelWidth: 200, pixelHeight: 100)
            },
            projectionProbe: { _ in
                NativeVideoProjectionInspection(primaryTrackID: 1, tag: nil)
            }
        )

        let prepared = try await preflight.prepare(
            videoURLs: [video],
            stagingParent: root,
            requiredAtomicWorkspaceReserveBytes: 0,
            progress: { _, _ in }
        )
        defer { prepared.discard() }
        XCTAssertEqual(prepared.videos.count, 1)
    }

    func testVideoAdmissionRejectsChangedSnapshotBeforeActingOnPositiveProjectionTag() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("changed.mov")
        try Data("video".utf8).write(to: video)
        let preflight = VideoInputPreflight(
            limits: .init(
                maximumVideoCount: 1,
                maximumTotalBytes: 1_024,
                minimumFreeSpaceReserveBytes: 0,
                maximumConcurrentDecoders: 1
            ),
            availableCapacity: { _ in Int64.max },
            analyze: { _, _ in
                XCTFail("Changed projection evidence must not reach video analysis.")
                return validVideoAnalysis()
            },
            projectionProbe: { stagedURL in
                try? Data("mutated".utf8).write(to: stagedURL)
                return NativeVideoProjectionInspection(
                    primaryTrackID: 1,
                    tag: .equirectangular360
                )
            }
        )

        do {
            _ = try await preflight.prepare(
                videoURLs: [video],
                stagingParent: root,
                requiredAtomicWorkspaceReserveBytes: 0,
                progress: { _, _ in }
            )
            XCTFail("A changed staged snapshot must not produce a projection verdict.")
        } catch let failure as VideoInputPreflightFailure {
            XCTAssertEqual(failure.rejectedVideos.map(\.issue), [.copyFailed])
        }
    }

    func testVideoAdmissionRequiresProjectionAndAnalysisToNameTheSamePrimaryTrack() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("track-mismatch.mov")
        try Data("video".utf8).write(to: video)
        let preflight = VideoInputPreflight(
            limits: .init(
                maximumVideoCount: 1,
                maximumTotalBytes: 1_024,
                minimumFreeSpaceReserveBytes: 0,
                maximumConcurrentDecoders: 1
            ),
            availableCapacity: { _ in Int64.max },
            analyze: { _, _ in validVideoAnalysis() },
            projectionProbe: { _ in
                NativeVideoProjectionInspection(primaryTrackID: 2, tag: nil)
            }
        )

        do {
            _ = try await preflight.prepare(
                videoURLs: [video],
                stagingParent: root,
                requiredAtomicWorkspaceReserveBytes: 0,
                progress: { _, _ in }
            )
            XCTFail("Projection evidence from a sibling track must not authenticate analysis.")
        } catch let failure as VideoInputPreflightFailure {
            XCTAssertEqual(failure.rejectedVideos.map(\.issue), [.unreadableMedia])
        }
    }
}

private struct RawDecoderThatMustNotRun: RawPhotoDecoding {
    func inspect(stagedSource: URL, maximumProxyDimension: Int) throws -> RawPhotoInspection {
        XCTFail("Projection admission must run before RAW inspection.")
        throw RawPhotoDecodingError.unsupportedOrCorrupt
    }

    func develop(
        stagedSource: URL,
        destination: URL,
        maximumPixelDimension: Int
    ) throws -> RawPhotoDevelopment {
        XCTFail("Projection admission must run before RAW development.")
        throw RawPhotoDecodingError.unsupportedOrCorrupt
    }
}

private func validVideoAnalysis(
    pixelWidth: Int = 64,
    pixelHeight: Int = 48
) -> VideoInputAnalysisEvidence {
    VideoInputAnalysisEvidence(
        trackID: 1,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        durationSeconds: 1,
        nominalFrameRate: 30,
        isHDR: false,
        decodedFrameCount: 1,
        preferredTransform: .identity
    )
}

private func writeJPEG(
    at url: URL,
    width: Int,
    height: Int,
    gpanoPrefix: String = "GPano",
    gpanoProjectionType: String? = nil,
    usePanoramaViewer: String? = nil
) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = try XCTUnwrap(CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let image = try XCTUnwrap(context.makeImage())
    let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ))
    let metadata = CGImageMetadataCreateMutable()
    if gpanoProjectionType != nil || usePanoramaViewer != nil {
        var error: Unmanaged<CFError>?
        XCTAssertTrue(CGImageMetadataRegisterNamespaceForPrefix(
            metadata,
            "http://ns.google.com/photos/1.0/panorama/" as CFString,
            gpanoPrefix as CFString,
            &error
        ))
        XCTAssertNil(error)
    }
    if let gpanoProjectionType {
        XCTAssertTrue(CGImageMetadataSetValueWithPath(
            metadata,
            nil,
            "\(gpanoPrefix):ProjectionType" as CFString,
            gpanoProjectionType as CFString
        ))
    }
    if let usePanoramaViewer {
        XCTAssertTrue(CGImageMetadataSetValueWithPath(
            metadata,
            nil,
            "\(gpanoPrefix):UsePanoramaViewer" as CFString,
            usePanoramaViewer as CFString
        ))
    }
    CGImageDestinationAddImageAndMetadata(destination, image, metadata, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
}

private let sphericalV1UUID = Data([
    0xff, 0xcc, 0x82, 0x63, 0xf8, 0x55, 0x4a, 0x93,
    0x88, 0x14, 0x58, 0x7a, 0x02, 0x52, 0x1f, 0xdd,
])

private let sphericalV1XML = """
<rdf:SphericalVideo xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
 xmlns:GSpherical="http://ns.google.com/videos/1.0/spherical/">
 <GSpherical:Spherical>true</GSpherical:Spherical>
 <GSpherical:Stitched>true</GSpherical:Stitched>
 <GSpherical:ProjectionType>equirectangular</GSpherical:ProjectionType>
</rdf:SphericalVideo>
"""

private func sphericalV1Fixture(trackID: UInt32) -> Data {
    isoBox("moov", payload: isoBox("trak", payload:
        trackHeader(trackID: trackID) + sphericalV1UUIDBox()
    ))
}

private func sphericalV1UUIDBox() -> Data {
    isoBox("uuid", payload: sphericalV1UUID + Data(sphericalV1XML.utf8))
}

private func sphericalV2Fixture(trackID: UInt32, halfHorizontalCoverage: Bool) -> Data {
    let rightBound: UInt32 = halfHorizontalCoverage ? 0x8000_0000 : 0
    let equi = isoBox("equi", payload:
        Data([0, 0, 0, 0])
            + bigEndian(UInt32(0))
            + bigEndian(UInt32(0))
            + bigEndian(UInt32(0))
            + bigEndian(rightBound)
    )
    let projection = isoBox("proj", payload:
        isoBox("prhd", payload: Data(repeating: 0, count: 16)) + equi
    )
    let spherical = isoBox("sv3d", payload:
        isoBox("svhd", payload: Data([0, 0, 0, 0]) + Data("EasySplat test".utf8))
            + projection
    )
    return isoBox("moov", payload: isoBox("trak", payload:
        trackHeader(trackID: trackID) + spherical
    ))
}

private func trackHeader(trackID: UInt32) -> Data {
    isoBox("tkhd", payload:
        Data([0, 0, 0, 7])
            + bigEndian(UInt32(0))
            + bigEndian(UInt32(0))
            + bigEndian(trackID)
            + bigEndian(UInt32(0))
    )
}

private func isoBox(_ type: String, payload: Data) -> Data {
    precondition(type.utf8.count == 4)
    return bigEndian(UInt32(8 + payload.count)) + Data(type.utf8) + payload
}

private func bigEndian(_ value: UInt32) -> Data {
    var value = value.bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}

private struct ISOFixtureBox {
    let type: String
    let start: Int
    let payloadStart: Int
    let end: Int
}

private func insertSphericalV1UUIDIntoFirstTrack(at url: URL) throws {
    var data = try Data(contentsOf: url)
    let topLevel = try isoFixtureBoxes(in: data, range: 0..<data.count)
    let movie = try XCTUnwrap(topLevel.first { $0.type == "moov" })
    let tracks = try isoFixtureBoxes(in: data, range: movie.payloadStart..<movie.end)
    let track = try XCTUnwrap(tracks.first { $0.type == "trak" })
    let metadata = sphericalV1UUIDBox()
    let newTrackSize = track.end - track.start + metadata.count
    let newMovieSize = movie.end - movie.start + metadata.count
    guard newTrackSize <= Int(UInt32.max), newMovieSize <= Int(UInt32.max) else {
        throw CocoaError(.fileWriteUnknown)
    }
    data.insert(contentsOf: metadata, at: track.end)
    data.replaceSubrange(
        track.start..<(track.start + 4),
        with: bigEndian(UInt32(newTrackSize))
    )
    data.replaceSubrange(
        movie.start..<(movie.start + 4),
        with: bigEndian(UInt32(newMovieSize))
    )
    try data.write(to: url, options: .atomic)
}

private func isoFixtureBoxes(in data: Data, range: Range<Int>) throws -> [ISOFixtureBox] {
    var boxes: [ISOFixtureBox] = []
    var cursor = range.lowerBound
    while cursor < range.upperBound {
        guard range.upperBound - cursor >= 8,
              let size = data.uint32ForFixture(at: cursor),
              size >= 8,
              Int(size) <= range.upperBound - cursor,
              let type = String(data: data[(cursor + 4)..<(cursor + 8)], encoding: .ascii) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let end = cursor + Int(size)
        boxes.append(ISOFixtureBox(
            type: type,
            start: cursor,
            payloadStart: cursor + 8,
            end: end
        ))
        cursor = end
    }
    return boxes
}

private extension Data {
    func uint32ForFixture(at offset: Int) -> UInt32? {
        guard offset >= 0, count >= offset + 4 else { return nil }
        return self[offset..<(offset + 4)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}
