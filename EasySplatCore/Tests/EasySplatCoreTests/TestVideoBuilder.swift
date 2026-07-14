import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import VideoToolbox

enum TestVideoBuilder {
    enum FixtureError: Error {
        case unsupportedCodec(String)
    }

    static func writeH264(
        to url: URL,
        times: [Double],
        levels: [UInt8],
        width: Int = 64,
        height: Int = 48,
        expectedFrameRate: Int = 30,
        keyFrameInterval: Int = 1,
        transform: CGAffineTransform = .identity
    ) async throws {
        precondition(!times.isEmpty && times.count == levels.count)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 500_000,
                AVVideoExpectedSourceFrameRateKey: expectedFrameRate,
                AVVideoMaxKeyFrameIntervalKey: max(1, keyFrameInterval),
                AVVideoAllowFrameReorderingKey: keyFrameInterval > 1,
                AVVideoProfileLevelKey: keyFrameInterval > 1
                    ? AVVideoProfileLevelH264HighAutoLevel
                    : AVVideoProfileLevelH264BaselineAutoLevel,
            ],
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw error("H.264 fixture settings are unavailable")
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )
        guard writer.canAdd(input) else {
            throw error("Could not add fixture video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? error("Could not start fixture writer")
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            throw error("Fixture pixel-buffer pool was unavailable")
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        for (index, seconds) in times.enumerated() {
            while !input.isReadyForMoreMediaData {
                guard clock.now < deadline else {
                    writer.cancelWriting()
                    throw error("Fixture writer timed out")
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            var optionalBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(
                nil,
                pool,
                &optionalBuffer
            ) == kCVReturnSuccess,
            let buffer = optionalBuffer else {
                throw error("Could not allocate fixture frame")
            }
            fill(buffer, level: levels[index], width: width, height: height)
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? error("Could not append fixture frame")
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? error("Fixture writer did not complete")
        }
    }

    static func writeHEVC10BitHLG(
        to url: URL,
        times: [Double],
        lumaLevels: [UInt16],
        width: Int = 64,
        height: Int = 48,
        expectedFrameRate: Int = 30,
        keyFrameInterval: Int = 30
    ) async throws {
        precondition(!times.isEmpty && times.count == lumaLevels.count)
        precondition(width.isMultiple(of: 2) && height.isMultiple(of: 2))
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 500_000,
                AVVideoExpectedSourceFrameRateKey: expectedFrameRate,
                AVVideoMaxKeyFrameIntervalKey: max(1, keyFrameInterval),
                AVVideoAllowFrameReorderingKey: true,
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
            ],
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw FixtureError.unsupportedCodec("HEVC Main10 HLG encoding is unavailable")
        }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )
        guard writer.canAdd(input) else {
            throw error("Could not add HEVC fixture video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? error("Could not start HEVC fixture writer")
        }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else {
            throw error("HEVC fixture pixel-buffer pool was unavailable")
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        for (index, seconds) in times.enumerated() {
            while !input.isReadyForMoreMediaData {
                guard clock.now < deadline else {
                    writer.cancelWriting()
                    throw error("HEVC fixture writer timed out")
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            var optionalBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(
                nil,
                pool,
                &optionalBuffer
            ) == kCVReturnSuccess,
            let buffer = optionalBuffer else {
                throw error("Could not allocate HEVC fixture frame")
            }
            try fillP010(buffer, lumaLevel: lumaLevels[index])
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? error("Could not append HEVC fixture frame")
            }
        }

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? error("HEVC fixture writer did not complete")
        }
    }

    private static func fill(
        _ buffer: CVPixelBuffer,
        level: UInt8,
        width: Int,
        height: Int
    ) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return }
        let base = baseAddress.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let pixel = row.advanced(by: x * 4)
                pixel[0] = level
                pixel[1] = level
                pixel[2] = level
                pixel[3] = 255
            }
        }
    }

    private static func fillP010(_ buffer: CVPixelBuffer, lumaLevel: UInt16) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard CVPixelBufferGetPixelFormatType(buffer)
                == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
              CVPixelBufferGetPlaneCount(buffer) == 2,
              let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
            throw error("HEVC fixture did not provide a writable P010 buffer")
        }

        CVBufferSetAttachment(
            buffer,
            kCVImageBufferColorPrimariesKey,
            kCVImageBufferColorPrimaries_ITU_R_2020,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferTransferFunctionKey,
            kCVImageBufferTransferFunction_ITU_R_2100_HLG,
            .shouldPropagate
        )
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferYCbCrMatrixKey,
            kCVImageBufferYCbCrMatrix_ITU_R_2020,
            .shouldPropagate
        )

        let videoRangeLuma = min(UInt16(940), max(UInt16(64), lumaLevel)) << 6
        let neutralChroma = UInt16(512) << 6
        let lumaWidth = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let lumaHeight = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let lumaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0..<lumaHeight {
            let row = lumaBase
                .advanced(by: y * lumaBytesPerRow)
                .assumingMemoryBound(to: UInt16.self)
            for x in 0..<lumaWidth {
                row[x] = videoRangeLuma
            }
        }

        let chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let chromaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for y in 0..<chromaHeight {
            let row = chromaBase
                .advanced(by: y * chromaBytesPerRow)
                .assumingMemoryBound(to: UInt16.self)
            for x in 0..<chromaWidth {
                row[x * 2] = neutralChroma
                row[x * 2 + 1] = neutralChroma
            }
        }
    }

    private static func error(_ message: String) -> NSError {
        NSError(
            domain: "TestVideoBuilder",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
