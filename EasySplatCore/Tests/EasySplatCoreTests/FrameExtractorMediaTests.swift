import AVFoundation
import CoreGraphics
import CoreVideo
import ImageIO
import XCTest
@testable import EasySplatCore

final class FrameExtractorMediaTests: XCTestCase {
    private let fixtureTimes = [0.0, 0.02, 0.50, 0.52, 1.00, 1.02, 1.50, 1.52]

    func testExtractionCompletesAtEOFUsesExactFrameAndAppliesDisplayTransform() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let videoURL = root.appendingPathComponent("fixture.mov")
        let outputURL = root.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputURL,
            withIntermediateDirectories: true
        )
        let levels = try await writeFixture(to: videoURL)

        let extractor = FrameExtractor()
        let options = FrameExtractionOptions(
            targetCount: 4,
            maxDimension: 128,
            targetFPS: 4,
            minDistanceRatio: 0,
            outputFormat: .png
        )
        let analysis = try await extractor.analyze(
            videoURL,
            options: options,
            progress: { _, _ in }
        )
        XCTAssertEqual(analysis.durationSeconds, 1.52, accuracy: 0.03)
        XCTAssertGreaterThanOrEqual(analysis.availableCandidateCount, 4)
        XCTAssertEqual(analysis.decodedFrameCount, fixtureTimes.count)
        XCTAssertFalse(analysis.hadRepairedTimestamps)
        XCTAssertTrue(analysis.candidates.allSatisfy { $0.presentationTime != nil })
        let outputs = try await extractor.extractFrames(
            from: analysis,
            targetCount: 4,
            to: outputURL,
            options: options,
            progress: { _, _ in }
        )

        XCTAssertEqual(outputs.count, 4)
        for output in outputs {
            let image = try loadImage(output)
            XCTAssertEqual(image.width, 48)
            XCTAssertEqual(image.height, 64)
        }

        let lastOutput = try XCTUnwrap(outputs.last)
        XCTAssertEqual(
            FrameExtractor.timestampSeconds(from: lastOutput.lastPathComponent) ?? -1,
            1.52,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            meanLuma(try loadImage(lastOutput)),
            Double(try XCTUnwrap(levels.last)),
            accuracy: 6
        )
    }

    func testSparseDecodeMatchesSequentialDecodeForClusteredVariableFrameTimes() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let videoURL = root.appendingPathComponent("fixture.mov")
        let sparseOutput = root.appendingPathComponent("sparse", isDirectory: true)
        let sequentialOutput = root.appendingPathComponent("sequential", isDirectory: true)
        try FileManager.default.createDirectory(at: sparseOutput, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sequentialOutput, withIntermediateDirectories: true)
        _ = try await writeFixture(to: videoURL)

        let extractor = FrameExtractor()
        let options = FrameExtractionOptions(
            targetCount: 2,
            maxDimension: 128,
            targetFPS: 4,
            minDistanceRatio: 0,
            outputFormat: .png
        )
        let original = try await extractor.analyze(
            videoURL,
            options: options,
            progress: { _, _ in }
        )
        let clustered = original.candidates.filter {
            abs($0.timestampSeconds - 1.50) < 0.001
                || abs($0.timestampSeconds - 1.52) < 0.001
        }
        XCTAssertEqual(clustered.count, 2)
        let sparseAnalysis = FrameExtractionAnalysis(
            videoURL: original.videoURL,
            primaryTrack: original.primaryTrack,
            durationSeconds: original.durationSeconds,
            preferredTransform: original.preferredTransform,
            candidates: clustered,
            decodedFrameCount: 100,
            hadRepairedTimestamps: false
        )
        let sequentialAnalysis = FrameExtractionAnalysis(
            videoURL: original.videoURL,
            primaryTrack: original.primaryTrack,
            durationSeconds: original.durationSeconds,
            preferredTransform: original.preferredTransform,
            candidates: clustered,
            decodedFrameCount: 2,
            hadRepairedTimestamps: false
        )

        let sparse = try await extractor.extractFrames(
            from: sparseAnalysis,
            targetCount: 2,
            to: sparseOutput,
            options: options,
            progress: { _, _ in }
        )
        let sequential = try await extractor.extractFrames(
            from: sequentialAnalysis,
            targetCount: 2,
            to: sequentialOutput,
            options: options,
            progress: { _, _ in }
        )

        XCTAssertEqual(sparse.count, 2)
        XCTAssertEqual(sequential.count, 2)
        XCTAssertEqual(
            sparse.map { FrameExtractor.timestampSeconds(from: $0.lastPathComponent) },
            [1.50, 1.52]
        )
        for (sparseURL, sequentialURL) in zip(sparse, sequential) {
            XCTAssertEqual(try Data(contentsOf: sparseURL), try Data(contentsOf: sequentialURL))
        }
    }

    func testSparseDecodeMatchesSequentialDecodeForInterFrameH264GOP() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let videoURL = root.appendingPathComponent("gop.mov")
        let sparseOutput = root.appendingPathComponent("sparse-gop", isDirectory: true)
        let sequentialOutput = root.appendingPathComponent("sequential-gop", isDirectory: true)
        let times = (0..<60).map { Double($0) / 30 }
        try await TestVideoBuilder.writeH264(
            to: videoURL,
            times: times,
            levels: times.indices.map { UInt8(96 + $0 % 12) },
            expectedFrameRate: 30,
            keyFrameInterval: 30
        )
        let nonSyncTimes = try await nonSyncSampleTimes(in: videoURL)
        XCTAssertGreaterThan(nonSyncTimes.count, 40)

        let extractor = FrameExtractor()
        let options = FrameExtractionOptions(
            targetCount: 60,
            maxDimension: 128,
            targetFPS: 30,
            minDistanceRatio: 0,
            outputFormat: .png
        )
        let original = try await extractor.analyze(
            videoURL,
            options: options,
            progress: { _, _ in }
        )
        XCTAssertEqual(original.decodedFrameCount, times.count)
        let nonSyncCandidates = original.candidates.filter { candidate in
            guard let presentationTime = candidate.presentationTime else { return false }
            return nonSyncTimes.contains { CMTimeCompare($0, presentationTime) == 0 }
        }
        let selected = SmartFrameSelection.selectTimeline(
            nonSyncCandidates,
            targetCount: 3,
            minimumTimeDistance: 0
        )
        XCTAssertEqual(selected.count, 3)
        XCTAssertEqual(
            FrameExtractor.test_secondPassStrategy(
                selected: selected,
                decodedFrameCount: original.decodedFrameCount,
                hadRepairedTimestamps: original.hadRepairedTimestamps
            ),
            .sparse
        )

        let sparseAnalysis = FrameExtractionAnalysis(
            videoURL: original.videoURL,
            primaryTrack: original.primaryTrack,
            durationSeconds: original.durationSeconds,
            preferredTransform: original.preferredTransform,
            candidates: selected,
            decodedFrameCount: original.decodedFrameCount,
            hadRepairedTimestamps: false
        )
        let sequentialAnalysis = FrameExtractionAnalysis(
            videoURL: original.videoURL,
            primaryTrack: original.primaryTrack,
            durationSeconds: original.durationSeconds,
            preferredTransform: original.preferredTransform,
            candidates: selected,
            decodedFrameCount: selected.count,
            hadRepairedTimestamps: false
        )
        var extractionOptions = options
        extractionOptions.targetCount = selected.count
        let sparse = try await extractor.extractFrames(
            from: sparseAnalysis,
            targetCount: selected.count,
            to: sparseOutput,
            options: extractionOptions,
            progress: { _, _ in }
        )
        let sequential = try await extractor.extractFrames(
            from: sequentialAnalysis,
            targetCount: selected.count,
            to: sequentialOutput,
            options: extractionOptions,
            progress: { _, _ in }
        )

        XCTAssertEqual(
            sparse.map { FrameExtractor.timestampSeconds(from: $0.lastPathComponent) },
            sequential.map { FrameExtractor.timestampSeconds(from: $0.lastPathComponent) }
        )
        for (sparseURL, sequentialURL) in zip(sparse, sequential) {
            XCTAssertEqual(try Data(contentsOf: sparseURL), try Data(contentsOf: sequentialURL))
        }
    }

    func testSparseAndSequentialExtractionHonorTrainingResolution() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let videoURL = root.appendingPathComponent("large-fixture.mov")
        let sparseOutput = root.appendingPathComponent("sparse-downscaled", isDirectory: true)
        let sequentialOutput = root.appendingPathComponent(
            "sequential-downscaled",
            isDirectory: true
        )
        let times = (0..<60).map { Double($0) / 30 }
        try await TestVideoBuilder.writeH264(
            to: videoURL,
            times: times,
            levels: times.indices.map { UInt8(48 + $0 % 160) },
            width: 320,
            height: 240,
            expectedFrameRate: 30,
            keyFrameInterval: 30
        )
        let extractor = FrameExtractor()
        let options = FrameExtractionOptions(
            targetCount: 60,
            maxDimension: 64,
            targetFPS: 30,
            minDistanceRatio: 0,
            outputFormat: .png
        )
        let original = try await extractor.analyze(
            videoURL,
            options: options,
            progress: { _, _ in }
        )
        let selected = SmartFrameSelection.selectTimeline(
            original.candidates,
            targetCount: 3,
            minimumTimeDistance: 0
        )
        XCTAssertEqual(selected.count, 3)
        XCTAssertEqual(
            FrameExtractor.test_secondPassStrategy(
                selected: selected,
                decodedFrameCount: original.decodedFrameCount,
                hadRepairedTimestamps: original.hadRepairedTimestamps
            ),
            .sparse
        )
        let sparseAnalysis = FrameExtractionAnalysis(
            videoURL: original.videoURL,
            primaryTrack: original.primaryTrack,
            durationSeconds: original.durationSeconds,
            preferredTransform: original.preferredTransform,
            candidates: selected,
            decodedFrameCount: original.decodedFrameCount,
            hadRepairedTimestamps: false
        )
        let sequentialAnalysis = FrameExtractionAnalysis(
            videoURL: original.videoURL,
            primaryTrack: original.primaryTrack,
            durationSeconds: original.durationSeconds,
            preferredTransform: original.preferredTransform,
            candidates: selected,
            decodedFrameCount: selected.count,
            hadRepairedTimestamps: false
        )
        var extractionOptions = options
        extractionOptions.targetCount = selected.count

        let sparse = try await extractor.extractFrames(
            from: sparseAnalysis,
            targetCount: selected.count,
            to: sparseOutput,
            options: extractionOptions,
            progress: { _, _ in }
        )
        let sequential = try await extractor.extractFrames(
            from: sequentialAnalysis,
            targetCount: selected.count,
            to: sequentialOutput,
            options: extractionOptions,
            progress: { _, _ in }
        )

        for output in sparse + sequential {
            let image = try loadImage(output)
            XCTAssertEqual(image.width, 64)
            XCTAssertEqual(image.height, 48)
        }
    }

    func testSparseDecodeToneMapsTenBitHLGVideo() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let videoURL = root.appendingPathComponent("hdr.mov")
        let sparseOutput = root.appendingPathComponent("hdr-sparse", isDirectory: true)
        let sequentialOutput = root.appendingPathComponent("hdr-sequential", isDirectory: true)
        let times = (0..<40).map { Double($0) / 30 }
        do {
            try await TestVideoBuilder.writeHEVC10BitHLG(
                to: videoURL,
                times: times,
                lumaLevels: times.indices.map { UInt16(160 + $0 * 8) }
            )
        } catch TestVideoBuilder.FixtureError.unsupportedCodec(let reason) {
            throw XCTSkip(reason)
        }

        let extractor = FrameExtractor()
        let options = FrameExtractionOptions(
            targetCount: 1,
            maxDimension: 128,
            targetFPS: 3,
            minDistanceRatio: 0,
            outputFormat: .png
        )
        let analysis = try await extractor.analyze(
            videoURL,
            options: options,
            progress: { _, _ in }
        )
        XCTAssertTrue(analysis.primaryTrack.isHDR)
        XCTAssertEqual(analysis.decodedFrameCount, times.count)
        XCTAssertFalse(analysis.hadRepairedTimestamps)
        let nonSyncTimes = try await nonSyncSampleTimes(in: videoURL)
        let selected = try XCTUnwrap(analysis.candidates.first { candidate in
            guard let presentationTime = candidate.presentationTime else { return false }
            return nonSyncTimes.contains { CMTimeCompare($0, presentationTime) == 0 }
        })
        XCTAssertEqual(
            FrameExtractor.test_secondPassStrategy(
                selected: [selected],
                decodedFrameCount: analysis.decodedFrameCount,
                hadRepairedTimestamps: analysis.hadRepairedTimestamps
            ),
            .sparse
        )

        let sparseAnalysis = FrameExtractionAnalysis(
            videoURL: analysis.videoURL,
            primaryTrack: analysis.primaryTrack,
            durationSeconds: analysis.durationSeconds,
            preferredTransform: analysis.preferredTransform,
            candidates: [selected],
            decodedFrameCount: analysis.decodedFrameCount,
            hadRepairedTimestamps: false
        )
        let sequentialAnalysis = FrameExtractionAnalysis(
            videoURL: analysis.videoURL,
            primaryTrack: analysis.primaryTrack,
            durationSeconds: analysis.durationSeconds,
            preferredTransform: analysis.preferredTransform,
            candidates: [selected],
            decodedFrameCount: 1,
            hadRepairedTimestamps: false
        )
        let sparse = try await extractor.extractFrames(
            from: sparseAnalysis,
            targetCount: 1,
            to: sparseOutput,
            options: options,
            progress: { _, _ in }
        )
        let sequential = try await extractor.extractFrames(
            from: sequentialAnalysis,
            targetCount: 1,
            to: sequentialOutput,
            options: options,
            progress: { _, _ in }
        )
        let sparseURL = try XCTUnwrap(sparse.first)
        let sequentialURL = try XCTUnwrap(sequential.first)
        XCTAssertEqual(
            FrameExtractor.timestampSeconds(from: sparseURL.lastPathComponent),
            FrameExtractor.timestampSeconds(from: sequentialURL.lastPathComponent)
        )
        let image = try loadImage(sparseURL)
        let sequentialImage = try loadImage(sequentialURL)
        XCTAssertEqual(image.width, sequentialImage.width)
        XCTAssertEqual(image.height, sequentialImage.height)
        XCTAssertTrue(zip(lumaPixels(image), lumaPixels(sequentialImage)).allSatisfy {
            abs(Int($0) - Int($1)) <= 1
        })
        XCTAssertEqual(image.width, 64)
        XCTAssertEqual(image.height, 48)
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertGreaterThan(meanLuma(image), 1)
        XCTAssertLessThan(meanLuma(image), 254)
    }

    func testSparseMissFallsBackWithoutPublishingPartialFrames() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let videoURL = root.appendingPathComponent("fixture.mov")
        let output = root.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let sentinel = output.appendingPathComponent("existing.txt")
        try Data("keep until publish".utf8).write(to: sentinel)
        _ = try await writeFixture(to: videoURL)
        let options = FrameExtractionOptions(
            targetCount: 5,
            maxDimension: 128,
            targetFPS: 4,
            minDistanceRatio: 0,
            outputFormat: .png
        )
        let extractor = FrameExtractor()
        let original = try await extractor.analyze(
            videoURL,
            options: options,
            progress: { _, _ in }
        )
        var candidates = Array(original.candidates.prefix(5))
        XCTAssertEqual(candidates.count, 5)
        candidates[4].presentationTime = CMTime(seconds: 100, preferredTimescale: 600)
        let forcedMiss = FrameExtractionAnalysis(
            videoURL: original.videoURL,
            primaryTrack: original.primaryTrack,
            durationSeconds: original.durationSeconds,
            preferredTransform: original.preferredTransform,
            candidates: candidates,
            decodedFrameCount: 100,
            hadRepairedTimestamps: false
        )

        let progress = FrameProgressRecorder()
        let frames = try await extractor.extractFrames(
            from: forcedMiss,
            targetCount: 5,
            to: output,
            options: options,
            progress: { fraction, _ in
                progress.append(
                    fraction: fraction,
                    destinationStillPresent: FileManager.default.fileExists(
                        atPath: sentinel.path
                    )
                )
            }
        )

        XCTAssertEqual(frames.count, 5)
        XCTAssertTrue(frames.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let observations = progress.observations
        XCTAssertTrue(zip(observations, observations.dropFirst()).allSatisfy {
            $1.fraction >= $0.fraction
        })
        XCTAssertTrue(observations.contains { $0.fraction > 0 && $0.fraction < 0.2 })
        XCTAssertTrue(observations.filter { $0.fraction < 1 }.allSatisfy(\.destinationStillPresent))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
        let siblings = try FileManager.default.contentsOfDirectory(
            at: output.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(siblings.contains { $0.lastPathComponent.contains(".tmp") })
    }

    func testCancelledSparseDecodeLeavesNoStagingDirectory() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let videoURL = root.appendingPathComponent("fixture.mov")
        let output = root.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = try await writeFixture(to: videoURL)
        let options = FrameExtractionOptions(
            targetCount: 1,
            maxDimension: 128,
            targetFPS: 4,
            minDistanceRatio: 0,
            outputFormat: .png
        )
        let extractor = FrameExtractor()
        let original = try await extractor.analyze(
            videoURL,
            options: options,
            progress: { _, _ in }
        )
        let sparse = FrameExtractionAnalysis(
            videoURL: original.videoURL,
            primaryTrack: original.primaryTrack,
            durationSeconds: original.durationSeconds,
            preferredTransform: original.preferredTransform,
            candidates: [try XCTUnwrap(original.candidates.first)],
            decodedFrameCount: 20,
            hadRepairedTimestamps: false
        )

        let task = Task<[URL], Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await extractor.extractFrames(
                from: sparse,
                targetCount: 1,
                to: output,
                options: options,
                progress: { _, _ in }
            )
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled extraction should not succeed")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil),
            []
        )
        let siblings = try FileManager.default.contentsOfDirectory(
            at: output.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(siblings.contains { $0.lastPathComponent.contains(".tmp") })
    }

    private func writeFixture(to url: URL) async throws -> [UInt8] {
        let width = 64
        let height = 48
        let levels = (0..<fixtureTimes.count).map { UInt8(32 + 26 * $0) }
        try await TestVideoBuilder.writeH264(
            to: url,
            times: fixtureTimes,
            levels: levels,
            width: width,
            height: height,
            expectedFrameRate: 4,
            transform: CGAffineTransform(
                a: 0,
                b: 1,
                c: -1,
                d: 0,
                tx: CGFloat(height),
                ty: 0
            )
        )
        return levels
    }

    private func nonSyncSampleTimes(in url: URL) async throws -> [CMTime] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw fixtureError("Fixture video track was unavailable")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else {
            throw fixtureError("Compressed fixture reader output was unavailable")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? fixtureError("Could not read compressed fixture samples")
        }
        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
            guard presentationTime.isValid,
                  presentationTime.isNumeric,
                  presentationTime.epoch == 0,
                  presentationTime.timescale > 0 else {
                continue
            }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sample,
                createIfNecessary: false
            ) as? [[CFString: Any]]
            let isNotSync = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? NSNumber)?
                .boolValue ?? false
            if isNotSync {
                times.append(presentationTime)
            }
        }
        guard reader.status == .completed else {
            throw reader.error ?? fixtureError("Compressed fixture reader failed")
        }
        return times
    }

    private func loadImage(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw fixtureError("Could not load extracted fixture frame")
        }
        return image
    }

    private func meanLuma(_ image: CGImage) -> Double {
        let pixels = lumaPixels(image)
        return Double(pixels.reduce(0) { $0 + Int($1) }) / Double(pixels.count)
    }

    private func lumaPixels(_ image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }

    private func fixtureError(_ message: String) -> NSError {
        NSError(
            domain: "FrameExtractorMediaTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private final class FrameProgressRecorder: @unchecked Sendable {
    struct Observation: Sendable {
        let fraction: Double
        let destinationStillPresent: Bool
    }

    private let lock = NSLock()
    private var values: [Observation] = []

    var observations: [Observation] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func append(fraction: Double, destinationStillPresent: Bool) {
        lock.lock()
        values.append(Observation(
            fraction: fraction,
            destinationStillPresent: destinationStillPresent
        ))
        lock.unlock()
    }
}
