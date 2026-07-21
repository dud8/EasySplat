import CoreGraphics
import EasySplatCore
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatReleaseVerifierCore

final class ReleaseVerificationProjectBuilderTests: XCTestCase {
    func testPublishesPhotoInputWithControlledReceipts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EasySplatReleaseVerificationProjectBuilderTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: false)
        for index in 0..<8 {
            try writePhoto(
                to: photos.appendingPathComponent("photo-\(index).png"),
                index: index
            )
        }
        let manifest = root.appendingPathComponent("release-input-manifest.json")
        try Data(
            #"{"photoFolder":"Photos","schemaVersion":1,"videos":[]}"#.utf8
        ).write(to: manifest)
        let resolvedInput = try PackagedProjectInputResolver.resolve(
            manifestURL: manifest,
            inputRoot: root
        )
        let requestedInput = InputSpec.photos(folder: photos.path)
        let options = RequestedRunOptions(detailProfile: .fast)
        let plan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: requestedInput,
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: DevelopmentOverrides(benchmarkSeed: 42)
        )

        let prepared = try await ReleaseVerificationProjectBuilder.prepare(
            resolvedInput: resolvedInput,
            requestedOptions: options,
            resolvedRunPlan: plan,
            projectParent: root.appendingPathComponent("Projects", isDirectory: true),
            title: "Offline"
        )
        defer { prepared.publication.attestation.discard() }

        let paths = ProjectPaths(root: prepared.publication.projectURL)
        let metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(metadata.input.photosFolder, "Originals/Photos")
        XCTAssertEqual(metadata.photoInputReceipts?.count, 8)
        XCTAssertNotNil(metadata.photoSelectionReceipt)
        XCTAssertEqual(prepared.input.photosFolder, metadata.input.photosFolder)
        XCTAssertEqual(prepared.input.videoFiles, metadata.input.videoFiles)
        try PhotoInputReceiptValidator.validateFiles(metadata: metadata, paths: paths)
    }

    private func writePhoto(to url: URL, index: Int) throws {
        let size = 64
        var pixels = [UInt8](repeating: UInt8(32 + index), count: size * size)
        for offset in 0..<16 {
            let x = (index * 7 + offset) % size
            let y = (index * 11 + offset * 3) % size
            pixels[y * size + x] = UInt8(160 + index)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                width: size,
                height: size,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: size,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
