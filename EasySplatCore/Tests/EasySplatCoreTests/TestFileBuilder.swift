import CoreGraphics
import Compression
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatCore

func makeTestTrainingResourceAdmission(
    resourcePolicy: ResourcePolicy = .automatic
) -> TrainingResourceAdmission {
    let clock = TrainingResourceClockEvidence(
        wallClock: Date(timeIntervalSince1970: 1_721_234_567),
        monotonicTicks: 123_456_789,
        machTimebaseNumerator: 125,
        machTimebaseDenominator: 3,
        bootTimeSeconds: 1_721_200_000,
        bootTimeMicroseconds: 123_456
    )
    let observation = makeTestTrainingResourceObservation(clock: clock)
    return try! TrainingMemoryBudget.admit(
        observation: observation,
        resourcePolicy: resourcePolicy,
        freshnessReference: clock
    )
}

private func makeTestTrainingResourceObservation(
    clock: TrainingResourceClockEvidence
) -> TrainingResourceObservation {
    let gibibyte: UInt64 = 1_073_741_824
    let pageSize: UInt64 = 16_384
    let available = 56 * gibibyte
    return TrainingResourceObservation(
        clock: clock,
        installedMemoryBytes: 64 * gibibyte,
        availableHostMemoryBytes: available,
        availableHostMemorySource: .machVMFreeInactive,
        kernelAvailableMemoryPercentage: nil,
        hostPages: HostMemoryPageEvidence(
            pageSizeBytes: pageSize,
            freePageCount: available / pageSize,
            inactivePageCount: 0,
            speculativePageCount: 0,
            purgeablePageCount: 0,
            compressedPageCount: 0
        ),
        memoryPressure: .normal,
        memoryPressureSource: .kernelMemorystatus,
        metalRecommendedWorkingSetBytes: 60 * gibibyte,
        metalCurrentAllocatedBytes: gibibyte
    )
}

struct TestTrainingResourceObserver: TrainingResourceObserving {
    func observe() throws -> TrainingResourceObservation {
        makeTestTrainingResourceObservation(
            clock: try LiveTrainingResourceObserver.captureClockEvidence()
        )
    }
}

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

    static func writeXYZOnlyPly(at url: URL, vertexCount: Int = 1) throws {
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

    static func writeMinimalPly(at url: URL, vertexCount: Int = 1) throws {
        let safeCount = max(1, vertexCount)
        let body = (0..<safeCount).map { _ in
            "0 0 0 1 1 1 -4 -4 -4 1 1 0 0 0"
        }.joined(separator: "\n")
        let text = """
        ply
        format ascii 1.0
        element vertex \(safeCount)
        property float x
        property float y
        property float z
        property float f_dc_0
        property float f_dc_1
        property float f_dc_2
        property float scale_0
        property float scale_1
        property float scale_2
        property float opacity
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        \(body)
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    static func writeControlledVideoReceipt(
        paths: ProjectPaths,
        index: Int = 0,
        bytes: Data = Data("test-video".utf8),
        safeDisplayName: String = "Capture.mov",
        analysisPolicy: VideoFrameAnalysisPolicy = VideoFrameAnalysisPolicy(
            targetFrameCeiling: 250,
            targetFPS: 3
        ),
        clipGroupID: String? = nil
    ) throws -> (url: URL, receipt: VideoInputReceipt) {
        try paths.ensureDirectories()
        let leaf = String(format: "video-%04d.mov", index)
        let relativePath = "Originals/\(leaf)"
        let url = paths.originalsURL.appendingPathComponent(leaf)
        try bytes.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        let sourceSHA256 = try GeometryArtifactStore.sha256(of: url)
        let resolvedClipGroupID = clipGroupID ?? String(format: "video_%03d", index)
        let artifact = VideoFrameAnalysisArtifact(
            sourceIndex: index,
            sourceProjectRelativePath: relativePath,
            sourceByteCount: Int64(bytes.count),
            sourceSHA256: sourceSHA256,
            clipGroupID: resolvedClipGroupID,
            policy: analysisPolicy,
            trackID: 1,
            pixelWidth: 64,
            pixelHeight: 48,
            durationSeconds: 1,
            nominalFrameRate: 30,
            isHDR: false,
            decodedFrameCount: 3,
            hadRepairedTimestamps: false,
            transformA: 1,
            transformB: 0,
            transformC: 0,
            transformD: 1,
            transformTX: 0,
            transformTY: 0,
            candidates: [0, 1, 2].map { frameIndex in
                VideoFrameAnalysisCandidate(
                    frameIndex: frameIndex,
                    timestampSeconds: Double(frameIndex) / 2,
                    presentationTimeValue: Int64(frameIndex * 15),
                    presentationTimeTimescale: 30,
                    sharpness: 1,
                    brightness: 0.5,
                    clippedFraction: 0,
                    motionScore: 0,
                    dHash: UInt64(frameIndex)
                )
            }
        )
        let analysisURL = paths.videoFrameAnalysisURL(index: index)
        let analysisEvidence = try VideoFrameAnalysisArtifactStore.save(
            artifact,
            to: analysisURL,
            projectPaths: paths
        )
        return (
            url,
            VideoInputReceipt(
                projectRelativePath: relativePath,
                safeDisplayName: safeDisplayName,
                byteCount: Int64(bytes.count),
                sha256: sourceSHA256,
                trackID: 1,
                pixelWidth: 64,
                pixelHeight: 48,
                durationSeconds: 1,
                nominalFrameRate: 30,
                isHDR: false,
                decodedFrameCount: 3,
                transformA: 1,
                transformB: 0,
                transformC: 0,
                transformD: 1,
                transformTX: 0,
                transformTY: 0,
                clipGroupID: resolvedClipGroupID,
                analysisPolicySHA256: analysisPolicy.sha256,
                analysisArtifactPath: try paths.projectRelativePath(for: analysisURL),
                analysisArtifactByteCount: analysisEvidence.byteCount,
                analysisArtifactSHA256: analysisEvidence.sha256
            )
        )
    }

    static func writeControlledPhotoReceipt(
        paths: ProjectPaths,
        index: Int = 0,
        size: Int = 16,
        value: UInt8 = 128,
        safeDisplayName: String = "Test Photo.jpg"
    ) throws -> (url: URL, receipt: PhotoInputReceipt) {
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(
            at: paths.importedPhotosURL,
            withIntermediateDirectories: true
        )
        let leaf = String(format: "photo-%04d.jpg", index)
        let relativePath = "Originals/Photos/\(leaf)"
        let url = paths.importedPhotosURL.appendingPathComponent(leaf)
        guard try writeGrayscaleImage(
            url: url,
            size: size,
            value: value,
            utType: .jpeg
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let sourceSHA256 = try GeometryArtifactStore.sha256(of: url)
        return (
            url,
            PhotoInputReceipt(
                projectRelativePath: relativePath,
                safeDisplayName: safeDisplayName,
                byteCount: byteCount,
                sha256: sourceSHA256,
                pixelWidth: size,
                pixelHeight: size,
                orientation: 1,
                typeIdentifier: "public.jpeg",
                analysisEvidence: photoAnalysisEvidence(
                    sourceSHA256: sourceSHA256,
                    seed: UInt8(truncatingIfNeeded: index)
                ),
                retainedRank: index
            )
        )
    }

    static func photoAnalysisEvidence(
        sourceSHA256: String,
        seed: UInt8 = 0
    ) -> PhotoAnalysisEvidence {
        PhotoAnalysisEvidence(
            sourceSHA256: sourceSHA256,
            spatialDescriptor: (0..<PhotoAnalysisEvidence.spatialDescriptorLength).map {
                seed &+ UInt8(truncatingIfNeeded: $0)
            },
            qualityBucket: seed,
            dHash: UInt64(seed),
            proxyPixelWidth: 256,
            proxyPixelHeight: 192,
            proxyPixelSHA256: String(repeating: "f", count: 64),
            analysisRecipeVersion: PhotoAnalysisEvidence.currentRecipeVersion,
            analysisRecipeSHA256: PhotoAnalysisEvidence.currentRecipeSHA256
        )
    }

    /// Metadata-only fixture. Tests that validate controlled files must persist a
    /// real artifact and use its measured size and digest instead.
    static func structuralPhotoSelectionReceipt(
        byteCount: Int64 = 1,
        sha256: String = String(repeating: "a", count: 64)
    ) -> PhotoSelectionReceipt {
        PhotoSelectionReceipt(
            projectRelativePath: PhotoSelectionReceipt.projectRelativePath,
            byteCount: byteCount,
            sha256: sha256,
            artifactSchemaVersion: PhotoSelectionArtifact.currentSchemaVersion,
            analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
            analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256,
            selectorPolicyVersion: PhotoDiversitySelector.selectorPolicyVersion,
            selectorPolicySHA256: PhotoDiversitySelector.selectorPolicySHA256
        )
    }

    static func bindContinuousPhotoSelectionFixture(
        to metadata: ProjectMetadata,
        paths: ProjectPaths
    ) throws -> ProjectMetadata {
        let receipts = metadata.photoInputReceipts ?? []
        guard !receipts.isEmpty,
              receipts.map(\.retainedRank) == Array(0..<receipts.count) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let artifact = PhotoSelectionArtifact(
            strategy: .continuousEvenSpacing,
            analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
            analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256,
            selectorPolicyVersion: PhotoDiversitySelector.selectorPolicyVersion,
            selectorPolicySHA256: PhotoDiversitySelector.selectorPolicySHA256,
            inputOrdering: .continuous,
            requestedPhotoSelection: .automatic,
            admissionCapacity: receipts.count,
            discoveredCount: receipts.count,
            acceptedCount: receipts.count,
            unreadableCount: 0,
            exactDuplicateCount: 0,
            companionDuplicateCount: 0,
            candidates: receipts.enumerated().map { index, receipt in
                PhotoSelectionCandidateArtifact(
                    admissionOrdinal: index,
                    evidence: receipt.analysisEvidence,
                    retainedRank: index
                )
            },
            retainedSourceSHA256s: receipts.map(\.source.sha256),
            canonicalRetainedSourceSHA256s: receipts.map(\.source.sha256)
        )
        let file = try PhotoSelectionArtifactStore.save(
            artifact,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths
        )
        var bound = metadata
        bound.requestedRunOptions.inputOrdering = .continuous
        bound.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: bound.requestedRunOptions,
            input: bound.input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        bound.photoSelectionReceipt = PhotoSelectionReceipt(
            projectRelativePath: PhotoSelectionReceipt.projectRelativePath,
            byteCount: file.byteCount,
            sha256: file.sha256,
            artifactSchemaVersion: artifact.schemaVersion,
            analysisRecipeVersion: artifact.analysisRecipeVersion,
            analysisRecipeSHA256: artifact.analysisRecipeSHA256,
            selectorPolicyVersion: artifact.selectorPolicyVersion,
            selectorPolicySHA256: artifact.selectorPolicySHA256
        )
        return bound
    }

    static func bindingControlledPhotoInput(
        to metadata: ProjectMetadata,
        paths: ProjectPaths
    ) throws -> ProjectMetadata {
        guard case .photos = metadata.input else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let fixture = try writeControlledPhotoReceipt(paths: paths)
        var controlled = metadata
        controlled.input = .photos(folder: "Originals/Photos")
        controlled.photoInputReceipts = [fixture.receipt]
        return controlled
    }
}

extension TestFileBuilder {
    static func writeMinimalRawDNG(to url: URL) throws {
        let compressed = try XCTUnwrap(Data(
            base64Encoded: """
            7dF/qF5zHMDx93PvtVjS3LZLt9GMtJYkSZIksUySkLQkW4i1tObSSFo3SWJpSZIkSZIkSZIk6UmSJEmSJEmSJEmSOffuwaWU/9/vU9/nfDq/nvM+r61bN3OAKS7cfusdV+zetX1hw5ab9y7ctucGDh6EEX+vyTb69/7/nv+v9Y87Dx2YYoZVHM5qjuQo1jDLWuY4lnnWczwb2MhJnMwmNnMKp3Iap3MGZ3IWZ3MO53Ie53MBW7iIi7mES7mMy7mSq7iabVzDtVzHDq7nRm5iJ7u4hd3sYYHb2cud3MXd7GORe7iX+7ifB9jPQ8MHephHeJTHeJwneJKneJpneJbneJ4XeJGXeJlXeJXXeJ03eJO3eJsx7/Au7/E+H/AhH/Exn/Apn/E5X/AlX/E13/At3/E9P/AjP/Ezv/Arv/G7vj99d3/67v703f3pu/vTd/en7+5P392fvrs/fXd/+u7+9N396bv703f3p+/uT9/dn767P313f/ru/vTd/em7+9N396fv7k/f3Z++uz99d3/67v703f3pu/vTd/en7+5P392fvrs/fXd/+u7+9N396bv703f3p+/uT9/dn767P313f/ru/vTd/em7+9N396fv7k/f3Z++uz99d3/67v703f3pu/vTd/en7+5P392fvrs/fXd/+u7+9N396bv703f3p+/uT9/dn767P313f/ru/vTd/em7+9N396fv7k/f3Z++uz99d3/67v703f3pu/vTd/en7+5P392fvrs/fXd/+u7+9N396bv703f3p+/uT9/dn767P313f/ru/vTd/em7+9N396fv7k/f3Z++uz99d3/67v703f3pu/vTd/en7+5P392fvrs/fXd/+u7+9N396bv703f3p+/uT9/dn767P313f/ru/vTd/em7+9N396fv7k/f3Z++uz99d3/67v703f3pu/vTd/en7+5P392fvrs/fXd/+u7+9N396bv703f3p+/uT9/dn767P313f/ru/vTd/em7+9N396fv7k/f3Z++uz99d3/67v703f3pu/vTd/en7+5P392fvrs/fXd/+u7+9N396bv703f3p+/uT9/dn767P313f/ru/vTd/em7+9N396fv7k/f3Z++uz99d3/67v703f3pu/vTd/en7+5P392fvrs/fXd/+u7+9N396bv703f3p+/uT9/dn767P313f/ru/vTd/em7+9N396fv7k/f3Z++uz99d3/67v703f3pu/vTd/en7+5P392fvrs/fXd/+u7+9N396bv703f3p+/uT9/dn767P313f/ru/vTd/em7+9N396fv7k/f3Z++uz99d3/67v703f3pu/vTd/en7+5P392fvrs/fXd/+u7+9N396bv703f3p+/uT9/dn767P313f/ru/vTd/em7+9N396fv7k/f3Z++uz99d3/67v703f3pu/vTd/en7+5P392fvrs/fXd/+u7+9N396bv703f3p+/uT1/dPzd8gBlGTLbRZB5+RivmqdH08rxmWNOTeWmtmswn7oOjJ9cfGNbsimvWrZjnVjzzmD/n4fOvX3HNg4vTw5Glo1PsXxwNb7d0YjQ1Oz40D7exdjw1IDGQwfx4+q/3P2582PI8P6wTxqs5YthvHNam4fj0sN85rG2T69ct/dd4ZvmZi5P7/wA=
            """,
            options: .ignoreUnknownCharacters
        ))
        var decoded = Data(count: 131_488)
        let decodedCount = decoded.withUnsafeMutableBytes { destination in
            compressed.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!,
                    destination.count,
                    source.bindMemory(to: UInt8.self).baseAddress!,
                    source.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard decodedCount == decoded.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try decoded.write(to: url, options: .atomic)
    }
}
