import Darwin
import Foundation
import XCTest
@testable import EasySplatCore

final class VideoInputReceiptTests: XCTestCase {
    func testMetadataStoreRequiresReceiptForEveryVideoAndBindsControlledLeaf() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: project)
        try paths.ensureDirectories()
        let video = paths.originalsURL.appendingPathComponent("video-0000.mov")
        try Data("immutable-video".utf8).write(to: video)
        let receipt = try makeReceipt(video: video, relativePath: "Originals/video-0000.mov")
        let metadata = ProjectMetadata(
            title: "Project",
            input: .video(files: ["Originals/video-0000.mov"]),
            videoInputReceipts: [receipt]
        )

        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let loaded = try ProjectMetadataStore.load(from: paths.metadataURL)

        XCTAssertEqual(loaded.videoInputReceipts, [receipt])
        XCTAssertNoThrow(try VideoInputReceiptValidator.validateFiles(
            metadata: loaded,
            paths: paths
        ))

        var missing = metadata
        missing.videoInputReceipts = nil
        XCTAssertThrowsError(try ProjectMetadataStore.save(missing, to: paths.metadataURL)) {
            XCTAssertEqual($0 as? VideoInputReceiptValidationError, .missingReceipts)
        }

        var external = metadata
        external.input = .video(files: [root.appendingPathComponent("external.mov").path])
        XCTAssertThrowsError(try ProjectMetadataStore.save(external, to: paths.metadataURL)) {
            XCTAssertEqual(
                $0 as? VideoInputReceiptValidationError,
                .inputPathMismatch(index: 0)
            )
        }
    }

    func testReceiptFileValidationRejectsPostAdoptionMutation() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: project)
        try paths.ensureDirectories()
        let video = paths.originalsURL.appendingPathComponent("video-0000.mov")
        try Data("immutable-video".utf8).write(to: video)
        let receipt = try makeReceipt(video: video, relativePath: "Originals/video-0000.mov")
        let metadata = ProjectMetadata(
            title: "Project",
            input: .video(files: ["Originals/video-0000.mov"]),
            videoInputReceipts: [receipt]
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        try Data("mutated-video!!".utf8).write(to: video)

        XCTAssertThrowsError(try VideoInputReceiptValidator.validateFiles(
            metadata: metadata,
            paths: paths
        )) { error in
            XCTAssertEqual(
                error as? VideoInputReceiptValidationError,
                .digestMismatch(index: 0)
            )
        }
    }

    func testReceiptPathsRejectAbsoluteTraversalAndSymlinkForms() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: project)
        try paths.ensureDirectories()
        let video = paths.originalsURL.appendingPathComponent("video-0000.mov")
        try Data("immutable-video".utf8).write(to: video)
        let valid = try makeReceipt(video: video, relativePath: "Originals/video-0000.mov")

        for unsafePath in [
            video.path,
            "Originals/../video-0000.mov",
            "Originals/subdirectory/video-0000.mov",
        ] {
            let receipt = replacingPath(in: valid, with: unsafePath)
            let metadata = ProjectMetadata(
                title: "Unsafe",
                input: .video(files: [unsafePath]),
                videoInputReceipts: [receipt]
            )
            XCTAssertThrowsError(try ProjectMetadataStore.save(metadata, to: paths.metadataURL)) {
                XCTAssertEqual(
                    $0 as? VideoInputReceiptValidationError,
                    .invalidReceipt(index: 0)
                )
            }
        }

        let outside = root.appendingPathComponent("outside.mov")
        try Data("immutable-video".utf8).write(to: outside)
        try FileManager.default.removeItem(at: video)
        try FileManager.default.createSymbolicLink(at: video, withDestinationURL: outside)
        let symlinked = ProjectMetadata(
            title: "Symlinked",
            input: .video(files: [valid.projectRelativePath]),
            videoInputReceipts: [valid]
        )
        XCTAssertThrowsError(try ProjectMetadataStore.save(symlinked, to: paths.metadataURL)) {
            XCTAssertEqual(
                $0 as? VideoInputReceiptValidationError,
                .invalidReceipt(index: 0)
            )
        }
    }

    func testMovedProjectRebindsRelativeVideoWithoutOriginalOrSecondCopy() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("client-secret-name.mov")
        let bytes = Data("portable-video".utf8)
        try bytes.write(to: source)
        let originalProject = root.appendingPathComponent("Original.easysplatproj")
        let originalPaths = ProjectPaths(root: originalProject)
        try originalPaths.ensureDirectories()
        let controlled = originalPaths.originalsURL.appendingPathComponent("video-0000.mov")
        try bytes.write(to: controlled)
        let receipt = try makeReceipt(
            video: controlled,
            relativePath: "Originals/video-0000.mov"
        )
        let metadata = ProjectMetadata(
            title: "Portable",
            input: .video(files: [receipt.projectRelativePath]),
            videoInputReceipts: [receipt]
        )
        try ProjectMetadataStore.save(metadata, to: originalPaths.metadataURL)
        try FileManager.default.removeItem(at: source)

        let movedProject = root.appendingPathComponent("Moved.easysplatproj")
        try FileManager.default.moveItem(at: originalProject, to: movedProject)
        let movedPaths = ProjectPaths(root: movedProject)
        let loaded = try ProjectMetadataStore.load(from: movedPaths.metadataURL)
        XCTAssertNoThrow(try VideoInputReceiptValidator.validateFiles(
            metadata: loaded,
            paths: movedPaths
        ))
        let before = try fileIdentity(at: movedPaths.originalsURL.appendingPathComponent("video-0000.mov"))
        let runner = PipelineRunner(
            projectURL: movedProject,
            config: .init(toolchain: TestToolchains.toolchainPaths(root: root))
        )
        XCTAssertEqual(
            try runner.importedVideoURLs(for: loaded.input.videoFiles, paths: movedPaths),
            [movedPaths.originalsURL.appendingPathComponent("video-0000.mov")]
        )
        try runner.importInputs(metadata: loaded, paths: movedPaths) { _, _ in }
        let after = try fileIdentity(at: movedPaths.originalsURL.appendingPathComponent("video-0000.mov"))
        XCTAssertEqual(after, before, "Import must recognize source and destination as the same controlled inode")
        XCTAssertEqual(
            try Data(contentsOf: movedPaths.originalsURL.appendingPathComponent("video-0000.mov")),
            bytes
        )

        let persisted = try String(contentsOf: movedPaths.metadataURL, encoding: .utf8)
        let diagnostic = try XCTUnwrap(ProjectDiagnosticBundle.build(projectURL: movedProject))
        XCTAssertFalse(persisted.contains(root.path))
        XCTAssertFalse(persisted.contains("client-secret-name.mov"))
        XCTAssertFalse(diagnostic.contains(root.path))
        XCTAssertFalse(diagnostic.contains("client-secret-name.mov"))
    }

    func testPipelineRejectsChangedVideoBeforeRepairingProjectDirectories() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project.easysplatproj")
        let paths = ProjectPaths(root: project)
        try paths.ensureDirectories()
        let fixture = try TestFileBuilder.writeControlledVideoReceipt(paths: paths)
        let metadata = ProjectMetadata(
            title: "Changed",
            input: .video(files: [fixture.receipt.projectRelativePath]),
            videoInputReceipts: [fixture.receipt]
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        try FileManager.default.removeItem(at: paths.framesRawURL.deletingLastPathComponent())
        try Data("tampered!!".utf8).write(to: fixture.url)

        let runner = PipelineRunner(
            projectURL: project,
            config: .init(toolchain: TestToolchains.toolchainPaths(root: root)),
            powerAssertion: RecordingPowerAssertion()
        )
        do {
            try await runner.run { _ in }
            XCTFail("Pipeline mutation must not start with changed controlled video bytes")
        } catch let error as VideoInputReceiptValidationError {
            XCTAssertEqual(error, .digestMismatch(index: 0))
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: paths.framesRawURL.deletingLastPathComponent().path
            ),
            "ensureDirectories must not repair the project before video byte validation"
        )
    }

    func testTrainerOnlyPlanChangeDoesNotRegenerateVideoAnalysis() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("Project.easysplatproj")
        let paths = ProjectPaths(root: project)
        try paths.ensureDirectories()
        let video = paths.originalsURL.appendingPathComponent("video-0000.mov")
        try Data("immutable-video".utf8).write(to: video)
        let input = InputSpec.video(files: ["Originals/video-0000.mov"])
        let options = RequestedRunOptions(detailProfile: .fast)
        let plan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        let receipt = try makeReceipt(
            video: video,
            relativePath: "Originals/video-0000.mov",
            policy: VideoFrameAnalysisPolicy(resolvedRunPlan: plan)
        )
        let metadata = ProjectMetadata(
            title: "Trainer-only change",
            input: input,
            videoInputReceipts: [receipt],
            requestedRunOptions: options,
            resolvedRunPlan: plan
        )
        var trainerOnlyPlan = plan
        trainerOnlyPlan.trainerIterationLimit += 1
        let runner = PipelineRunner(
            projectURL: project,
            config: .init(toolchain: TestToolchains.toolchainPaths(root: root))
        )

        XCTAssertFalse(try runner.videoFrameAnalysisRequiresRefresh(
            metadata: metadata,
            currentPlan: trainerOnlyPlan
        ))
        var analysisPlan = plan
        analysisPlan.analysisFrameRate += 1
        XCTAssertTrue(try runner.videoFrameAnalysisRequiresRefresh(
            metadata: metadata,
            currentPlan: analysisPlan
        ))
    }

    private func makeReceipt(
        video: URL,
        relativePath: String,
        policy: VideoFrameAnalysisPolicy = VideoFrameAnalysisPolicy(
            targetFrameCeiling: 1,
            targetFPS: 1
        )
    ) throws -> VideoInputReceipt {
        let paths = ProjectPaths(root: video.deletingLastPathComponent().deletingLastPathComponent())
        let sourceSHA256 = try GeometryArtifactStore.sha256(of: video)
        let artifact = VideoFrameAnalysisArtifact(
            sourceIndex: 0,
            sourceProjectRelativePath: relativePath,
            sourceByteCount: Int64(try Data(contentsOf: video).count),
            sourceSHA256: sourceSHA256,
            clipGroupID: "video_000",
            policy: policy,
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
            candidates: [0, 1, 2].map { index in
                .init(
                    frameIndex: index,
                    timestampSeconds: Double(index) / 2,
                    presentationTimeValue: Int64(index * 15),
                    presentationTimeTimescale: 30,
                    sharpness: 1,
                    brightness: 0.5,
                    clippedFraction: 0,
                    motionScore: 0,
                    dHash: UInt64(index)
                )
            }
        )
        let analysisURL = paths.videoFrameAnalysisURL(index: 0)
        let analysis = try VideoFrameAnalysisArtifactStore.save(
            artifact,
            to: analysisURL,
            projectPaths: paths
        )
        return VideoInputReceipt(
            projectRelativePath: relativePath,
            safeDisplayName: "Capture.mov",
            byteCount: Int64(try Data(contentsOf: video).count),
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
            clipGroupID: "video_000",
            analysisPolicySHA256: policy.sha256,
            analysisArtifactPath: try paths.projectRelativePath(for: analysisURL),
            analysisArtifactByteCount: analysis.byteCount,
            analysisArtifactSHA256: analysis.sha256
        )
    }

    private func replacingPath(
        in receipt: VideoInputReceipt,
        with path: String
    ) -> VideoInputReceipt {
        VideoInputReceipt(
            projectRelativePath: path,
            safeDisplayName: receipt.safeDisplayName,
            byteCount: receipt.byteCount,
            sha256: receipt.sha256,
            trackID: receipt.trackID,
            pixelWidth: receipt.pixelWidth,
            pixelHeight: receipt.pixelHeight,
            durationSeconds: receipt.durationSeconds,
            nominalFrameRate: receipt.nominalFrameRate,
            isHDR: receipt.isHDR,
            decodedFrameCount: receipt.decodedFrameCount,
            transformA: receipt.transformA,
            transformB: receipt.transformB,
            transformC: receipt.transformC,
            transformD: receipt.transformD,
            transformTX: receipt.transformTX,
            transformTY: receipt.transformTY,
            clipGroupID: receipt.clipGroupID,
            analysisPolicySHA256: receipt.analysisPolicySHA256,
            analysisArtifactPath: receipt.analysisArtifactPath,
            analysisArtifactByteCount: receipt.analysisArtifactByteCount,
            analysisArtifactSHA256: receipt.analysisArtifactSHA256
        )
    }

    private func fileIdentity(at url: URL) throws -> String {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw CocoaError(.fileReadUnknown) }
        return "\(status.st_dev):\(status.st_ino):\(status.st_size):\(status.st_mtimespec.tv_sec):\(status.st_ctimespec.tv_sec)"
    }
}
