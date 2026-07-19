#if canImport(XCTest)
import Darwin
import Foundation
import XCTest
@testable import EasySplatCore
import ImageIO
import UniformTypeIdentifiers
import SQLite3

final class PipelineIntegrationTests: XCTestCase {
    private var automaticTrainingMemoryBudgetBytes: Int64 {
        TrainingMemoryBudget.resolve(
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            resourcePolicy: .automatic
        )
    }

    private func makePipelineConfig(
        toolchain: ToolchainPaths,
        candidateRoute: SfmBackend? = nil,
        skipTraining: Bool = false,
        stopAfterStage: PipelineStage? = nil,
        resolvedRunPlan: ResolvedRunPlan? = nil,
        hardwareProfile: HardwareProfile? = HardwareProfile(
            memoryGB: 48,
            cpuCount: 16,
            gpuWorkingSetGB: 36
        )
    ) -> PipelineRunner.PipelineConfig {
        PipelineRunner.PipelineConfig(
            toolchain: toolchain,
            developmentOverrides: DevelopmentOverrides(
                candidateRoute: candidateRoute,
                stopAfterStage: stopAfterStage,
                skipTraining: skipTraining
            ),
            hardwareProfile: hardwareProfile,
            resolvedRunPlan: resolvedRunPlan
        )
    }

    func testDevelopmentStopAfterFeatureExtractionEndsWithoutStartingMatching() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("StopAfterFeatures.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<8 {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(index)
            )
        }

        let metadata = ProjectMetadata(
            title: "Stop after features",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(metadata, paths: paths)
        let toolchain = try makeToolchain(root: temp)
        let subprocess = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--FeatureExtraction.max_image_size", in: args), "1232")
                    XCTAssertNil(self.value(for: "--SiftExtraction.max_image_size", in: args))
                    try? self.writeFeatureDatabase(for: args)
                }
            )
        ])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                stopAfterStage: .sfmFeatures
            ),
            tooling: .init(runner: subprocess)
        )

        try await pipeline.run { _ in }

        XCTAssertEqual(subprocess.calls.map { $0.1.first }, ["feature_extractor"])
        let stoppedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(stoppedMetadata.state.stage, .sfmFeatures)
        XCTAssertNil(stoppedMetadata.state.lastError)
        XCTAssertNil(stoppedMetadata.lastRunStartedAt)
        XCTAssertNil(stoppedMetadata.checkpoint)
        let featureEvidence = try ColmapFeatureEvidenceStore.load(
            from: paths.colmapFeatureEvidenceURL,
            projectPaths: paths
        )
        XCTAssertEqual(featureEvidence.cameraGroupingReceipt.mode, .preserveExisting)
        XCTAssertEqual(featureEvidence.cameraGroupingReceipt.cameraCountBefore, 8)
        XCTAssertEqual(featureEvidence.cameraGroupingReceipt.cameraCountAfter, 8)
        XCTAssertEqual(featureEvidence.cameraGroupingReceipt.groupedVideoSourceCount, 0)
        XCTAssertEqual(featureEvidence.cameraGroupingReceipt.groups, [])
        XCTAssertEqual(
            featureEvidence.featureDatabaseDigest,
            try ColmapDatabaseDigester.digests(at: paths.colmapDatabaseURL).feature
        )
        for suffix in ["-wal", "-shm", "-journal"] {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: paths.colmapDatabaseURL.path + suffix
            ))
        }
    }

    func testFeatureBoundaryRejectsCompletionOrderDatabaseIDsBeforePublishingEvidence() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent(
            "UnstableFeatureIDs.easysplatproj",
            isDirectory: true
        )
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<4 {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(index)
            )
        }
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(
            ProjectMetadata(
                title: "Unstable feature IDs",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    capturePath: .orbit,
                    detailProfile: .balanced
                )
            ),
            paths: paths
        )
        let toolchain = try makeToolchain(root: temp)
        let subprocess = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    try self.writeFeatureDatabase(for: args, reverseStableIDs: true)
                }
            )
        ])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                stopAfterStage: .sfmFeatures
            ),
            tooling: .init(runner: subprocess)
        )

        await XCTAssertThrowsErrorAsync({
            try await pipeline.run { _ in }
        }, errorHandler: { error in
            guard case .unstableImageID = error as? ColmapFeatureDatabaseIdentityError else {
                return XCTFail("Unexpected error: \(error)")
            }
        })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.colmapFeatureEvidenceURL.path
        ))
        XCTAssertEqual(subprocess.calls.map { $0.1.first }, ["feature_extractor"])
    }

    func testDevelopmentStopAfterClassicalMatchingPublishesOnlyDurableMatchingBoundary() async throws {
        let temp = makeTempRoot()
        let fixture = try makePhotoRecoveryProject(
            in: temp,
            name: "StopAfterClassicalMatching",
            photoCount: 8
        )
        let run = makePhotoRecoveryPipeline(
            projectURL: fixture.projectURL,
            toolchain: fixture.toolchain,
            scripts: [
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["feature_extractor"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { try self.writeFeatureDatabase(for: $0) }
                ),
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["matches_importer"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: {
                        try self.writeVerifiedPairResults(for: $0)
                        try self.leavePersistentWALResidue(for: $0)
                    }
                ),
            ],
            stopAfterStage: .sfmMatching
        )

        try await run.pipeline.run { _ in }

        let stoppedMetadata = try ProjectMetadataStore.load(
            from: fixture.paths.metadataURL
        )
        XCTAssertEqual(stoppedMetadata.state.stage, .sfmMatching)
        XCTAssertNil(stoppedMetadata.state.lastError)
        XCTAssertNil(stoppedMetadata.checkpoint)
        XCTAssertNil(stoppedMetadata.lastRunStartedAt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.geometryManifestURL.path))

        let selectedFrames = try run.pipeline.loadSelectedFrameManifest(
            from: fixture.paths.framesSelectedManifestURL
        )
        XCTAssertEqual(selectedFrames.count, 8)
        XCTAssertEqual(
            try run.pipeline.test_validateStageOutput(
                .selectFrames,
                paths: fixture.paths,
                metadata: stoppedMetadata
            ),
            .valid
        )
        XCTAssertEqual(
            try run.pipeline.test_validateStageOutput(
                .sfmFeatures,
                paths: fixture.paths,
                metadata: stoppedMetadata
            ),
            .valid
        )
        XCTAssertEqual(
            try run.pipeline.test_validateStageOutput(
                .sfmMatching,
                paths: fixture.paths,
                metadata: stoppedMetadata
            ),
            .valid
        )

        let imageNames = selectedImageNames(in: fixture.paths)
        _ = try ColmapFeatureEvidenceStore.load(
            from: fixture.paths.colmapFeatureEvidenceURL,
            projectPaths: fixture.paths
        )
        let pairEvidence = try PairGraphEvidenceStore.loadVerified(
            from: fixture.paths.pairGraphEvidenceURL,
            expectedImageNames: imageNames,
            databaseURL: fixture.paths.colmapDatabaseURL,
            projectPaths: fixture.paths
        )
        let workerExecution = try GeometryWorkerExecutionArtifactStore.load(
            from: fixture.paths.workerExecutionURL,
            projectPaths: fixture.paths
        )
        let workerBudget = try XCTUnwrap(
            stoppedMetadata.resolvedRunPlan?.geometryWorkerBudget
        )
        XCTAssertNoThrow(try workerExecution.validate(expectedBudget: workerBudget))
        XCTAssertNoThrow(try PairGraphEvidenceStore.validateWorkerExecution(
            pairEvidence,
            workerExecution: workerExecution
        ))
        XCTAssertTrue(workerExecution.mappingAndRefinementInvocations.isEmpty)

        let canonicalSparseModel = fixture.paths.colmapSparseURL
            .appendingPathComponent("0", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.geometryManifestURL.path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: canonicalSparseModel.path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.trainingManifestURL.path
        ))
        XCTAssertEqual(
            run.runner.calls.compactMap { $0.1.first },
            ["feature_extractor", "matches_importer"]
        )
        XCTAssertFalse(run.runner.calls.contains {
            $0.0 == fixture.toolchain.msplat.path
        })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.colmapDatabaseURL.path + "-wal"
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.colmapDatabaseURL.path + "-shm"
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.colmapDatabaseURL.path + "-journal"
        ))
        let databaseHeader = try Data(
            contentsOf: fixture.paths.colmapDatabaseURL,
            options: .mappedIfSafe
        )
        XCTAssertGreaterThanOrEqual(databaseHeader.count, 20)
        XCTAssertEqual(databaseHeader[18], 1)
        XCTAssertEqual(databaseHeader[19], 1)
    }

    func testResumeReextractsFeaturesWhenCameraGroupingReceiptUsesWrongPolicy() async throws {
        let temp = makeTempRoot()
        let fixture = try makePhotoRecoveryProject(
            in: temp,
            name: "WrongCameraGroupingReceipt",
            photoCount: 8
        )
        let initial = makePhotoRecoveryPipeline(
            projectURL: fixture.projectURL,
            toolchain: fixture.toolchain,
            scripts: [
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["feature_extractor"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { try self.writeFeatureDatabase(for: $0) }
                ),
            ],
            stopAfterStage: .sfmFeatures
        )
        try await initial.pipeline.run { _ in }

        let original = try ColmapFeatureEvidenceStore.load(
            from: fixture.paths.colmapFeatureEvidenceURL,
            projectPaths: fixture.paths
        )
        let wrongReceipt = ColmapCameraGroupingReceipt(
            mode: .allSelectedImagesShared,
            cameraCountBefore: 8,
            cameraCountAfter: 1,
            groupedVideoSourceCount: 0,
            groups: [
                ColmapCameraGroupReceipt(
                    sourceGroupID: "all-selected-images",
                    memberCount: 8,
                    canonicalCameraID: 1
                )
            ]
        )
        try ColmapFeatureEvidenceStore.save(
            ColmapFeatureEvidence(
                selectedFramesDigest: original.selectedFramesDigest,
                imageNames: original.imageNames,
                featureDatabaseDigest: original.featureDatabaseDigest,
                cameraGroupingReceipt: wrongReceipt,
                cameraInitializationReceipt: original.cameraInitializationReceipt
            ),
            to: fixture.paths.colmapFeatureEvidenceURL,
            projectPaths: fixture.paths
        )

        let resumed = makePhotoRecoveryPipeline(
            projectURL: fixture.projectURL,
            toolchain: fixture.toolchain,
            scripts: [
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["feature_extractor"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { try self.writeFeatureDatabase(for: $0) }
                ),
            ],
            stopAfterStage: .sfmFeatures
        )
        let events = PipelineEventSink()
        try await resumed.pipeline.run(resumeFrom: .sfmFeatures) { events.append($0) }

        XCTAssertEqual(
            resumed.runner.calls.filter { $0.1.first == "feature_extractor" }.count,
            1
        )
        XCTAssertNotNil(events.stageLog(containing: "partial/corrupt stage output"))
        let repaired = try ColmapFeatureEvidenceStore.load(
            from: fixture.paths.colmapFeatureEvidenceURL,
            projectPaths: fixture.paths
        )
        XCTAssertEqual(repaired.cameraGroupingReceipt.mode, .preserveExisting)
        XCTAssertEqual(repaired.cameraGroupingReceipt.cameraCountAfter, 8)
    }

    func testMultiVideoSelectionUsesExactGlobalBudgetAndCleansCommittedRawFrames() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent(
            "MixedVideoSelection.easysplatproj",
            isDirectory: true
        )
        let firstVideo = temp.appendingPathComponent("first.mov")
        let secondVideo = temp.appendingPathComponent("second.mov")
        let firstTimes = [0.0, 0.02, 0.20, 0.22, 0.40, 0.42, 0.60, 0.62]
        let secondTimes = [0.0, 0.03, 0.15, 0.30]
        do {
            try await TestVideoBuilder.writeH264(
                to: firstVideo,
                times: firstTimes,
                levels: firstTimes.indices.map { UInt8(30 + $0 * 20) }
            )
            try await TestVideoBuilder.writeH264(
                to: secondVideo,
                times: secondTimes,
                levels: secondTimes.indices.map { UInt8(50 + $0 * 30) }
            )
        } catch TestVideoBuilder.FixtureError.unsupportedCodec(let reason) {
            throw XCTSkip(reason)
        }
        let paths = ProjectPaths(root: projectURL)
        let requestedOptions = RequestedRunOptions(detailProfile: .fast)
        let adopted = try await adoptVideoFixtures(
            [firstVideo, secondVideo],
            requestedOptions: requestedOptions,
            paths: paths
        )
        let firstReceipt = adopted.receipts[0]
        let secondReceipt = adopted.receipts[1]

        let metadata = ProjectMetadata(
            title: "Multi-video selection",
            input: adopted.input,
            videoInputReceipts: adopted.receipts,
            requestedRunOptions: requestedOptions
        )
        try saveFixtureMetadata(metadata, paths: paths)
        let toolchain = try makeToolchain(root: temp)
        let events = PipelineEventSink()
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                stopAfterStage: .selectFrames
            ),
            tooling: .init(runner: MockSubprocessRunner(scripts: []))
        )

        try await pipeline.run { events.append($0) }

        let saved = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(saved.state.stage, .selectFrames)
        let manifest = try pipeline.loadSelectedFrameManifest(
            from: paths.framesSelectedManifestURL
        )
        let firstGroup = manifest.filter {
            $0.groupId == "video_sha256_\(firstReceipt.sha256)"
        }
        let secondGroup = manifest.filter {
            $0.groupId == "video_sha256_\(secondReceipt.sha256)"
        }
        XCTAssertEqual(firstGroup.count, firstTimes.count)
        XCTAssertEqual(secondGroup.count, secondTimes.count)
        XCTAssertEqual(manifest.count, firstTimes.count + secondTimes.count)
        XCTAssertEqual(firstGroup.first?.timestampSeconds ?? -1, firstTimes.first ?? -1, accuracy: 0.001)
        XCTAssertEqual(firstGroup.last?.timestampSeconds ?? -1, firstTimes.last ?? -1, accuracy: 0.001)
        XCTAssertEqual(secondGroup.first?.timestampSeconds ?? -1, secondTimes.first ?? -1, accuracy: 0.001)
        XCTAssertEqual(secondGroup.last?.timestampSeconds ?? -1, secondTimes.last ?? -1, accuracy: 0.001)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.framesRawURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.framesRawManifestURL.path))
        XCTAssertNotNil(events.stageLog(containing: "Using verified frame analysis"))
        XCTAssertNil(
            events.stageLog(containing: "Analyzing video-"),
            "The pipeline must not repeat the low-resolution preflight decode."
        )

        let extractionProgress = events.progressFractions(for: .extractFrames)
        XCTAssertFalse(extractionProgress.isEmpty)
        XCTAssertTrue(zip(extractionProgress, extractionProgress.dropFirst()).allSatisfy {
            $1 >= $0
        })
        XCTAssertEqual(extractionProgress.last ?? -1, 1, accuracy: 0.000_001)
        let selectionProgress = events.progressFractions(for: .selectFrames)
        XCTAssertFalse(selectionProgress.isEmpty)
        XCTAssertTrue(zip(selectionProgress, selectionProgress.dropFirst()).allSatisfy {
            $1 >= $0
        })
        XCTAssertEqual(selectionProgress.last ?? -1, 1, accuracy: 0.000_001)
    }

    func testPlanChangeRegeneratesVideoAnalysisWithoutTouchingControlledOriginals() async throws {
        let temp = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: temp) }
        let projectURL = temp.appendingPathComponent(
            "VideoAnalysisPlanChange.easysplatproj",
            isDirectory: true
        )
        let firstVideo = temp.appendingPathComponent("plan-change-a.mov")
        let secondVideo = temp.appendingPathComponent("plan-change-b.mov")
        do {
            try await TestVideoBuilder.writeH264(
                to: firstVideo,
                times: [0, 0.2, 0.4],
                levels: [20, 80, 140]
            )
            try await TestVideoBuilder.writeH264(
                to: secondVideo,
                times: [0, 0.2, 0.4],
                levels: [50, 110, 170]
            )
        } catch TestVideoBuilder.FixtureError.unsupportedCodec(let reason) {
            throw XCTSkip(reason)
        }

        let paths = ProjectPaths(root: projectURL)
        let options = RequestedRunOptions(detailProfile: .fast)
        let adopted = try await adoptVideoFixtures(
            [firstVideo, secondVideo],
            requestedOptions: options,
            paths: paths
        )
        let hardware = HardwareProfile(
            memoryGB: 48,
            cpuCount: 16,
            gpuWorkingSetGB: 36
        )
        let previousPlan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: adopted.input,
            hardware: hardware,
            developmentOverrides: .none
        )
        var currentPlan = previousPlan
        currentPlan.analysisFrameRate += 1
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .selectFrames,
                input: adopted.input,
                previousPlan: previousPlan,
                currentPlan: currentPlan
            ),
            .importInput
        )
        let interrupted = ProjectMetadata(
            title: "Video analysis plan change",
            input: adopted.input,
            videoInputReceipts: adopted.receipts,
            requestedRunOptions: options,
            resolvedRunPlan: previousPlan,
            state: PipelineState(stage: .selectFrames, lastError: nil),
            lastRunStartedAt: Date(timeIntervalSince1970: 1)
        )
        try ProjectMetadataStore.save(interrupted, to: paths.metadataURL)
        let controlledURLs = try adopted.receipts.map {
            try paths.resolveProjectRelativePath($0.projectRelativePath)
        }
        let originalDigests = try controlledURLs.map {
            try GeometryArtifactStore.sha256(of: $0)
        }
        let originalInodes = try controlledURLs.map { url -> UInt64 in
            var status = stat()
            guard lstat(url.path, &status) == 0 else {
                throw POSIXError(.ENOENT)
            }
            return UInt64(status.st_ino)
        }
        let oldAnalysisURLs = try adopted.receipts.map {
            try paths.resolveProjectRelativePath($0.analysisArtifactPath)
        }
        let oldAnalysisBytes = try oldAnalysisURLs.map { try Data(contentsOf: $0) }
        let toolchain = try makeToolchain(root: temp)
        let cancelled = PipelineRunner(
            projectURL: projectURL,
            config: PipelineRunner.PipelineConfig(
                toolchain: toolchain,
                developmentOverrides: DevelopmentOverrides(
                    candidateRoute: .colmap,
                    stopAfterStage: .selectFrames
                ),
                hardwareProfile: hardware,
                resolvedRunPlan: currentPlan
            ),
            tooling: .init(
                runner: MockSubprocessRunner(scripts: []),
                checkCancellation: { throw CancellationError() }
            )
        )

        await XCTAssertThrowsErrorAsync({
            try await cancelled.run(resumeFrom: .selectFrames) { _ in }
        }, errorHandler: { error in
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        })

        let afterCancellation = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(afterCancellation.resolvedRunPlan, previousPlan)
        XCTAssertEqual(afterCancellation.videoInputReceipts, adopted.receipts)
        for (url, bytes) in zip(oldAnalysisURLs, oldAnalysisBytes) {
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        let analysisFilesAfterCancellation = try FileManager.default.contentsOfDirectory(
            at: paths.framesRawURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("video-analysis-") }
        XCTAssertEqual(
            Set(analysisFilesAfterCancellation.map(\.lastPathComponent)),
            Set(oldAnalysisURLs.map(\.lastPathComponent))
        )

        // Reproduce the historical torn handoff exactly: the new plan reached
        // project.json, but its receipts still identify the old analysis policy.
        // One relaunch must heal this state; requiring an older plan here would
        // leave the project in a permanent policyMismatch loop.
        var stranded = afterCancellation
        stranded.resolvedRunPlan = currentPlan
        try ProjectMetadataStore.save(stranded, to: paths.metadataURL)

        let resumedEvents = PipelineEventSink()
        let resumed = PipelineRunner(
            projectURL: projectURL,
            config: PipelineRunner.PipelineConfig(
                toolchain: toolchain,
                developmentOverrides: DevelopmentOverrides(
                    candidateRoute: .colmap,
                    stopAfterStage: .selectFrames
                ),
                hardwareProfile: hardware,
                resolvedRunPlan: currentPlan
            ),
            tooling: .init(runner: MockSubprocessRunner(scripts: []))
        )
        try await resumed.run(resumeFrom: .selectFrames) { resumedEvents.append($0) }

        let regenerated = try ProjectMetadataStore.load(from: paths.metadataURL)
        let receipts = try XCTUnwrap(regenerated.videoInputReceipts)
        XCTAssertEqual(regenerated.resolvedRunPlan, currentPlan)
        XCTAssertEqual(regenerated.state.stage, .selectFrames)
        XCTAssertEqual(receipts.count, adopted.receipts.count)
        XCTAssertTrue(receipts.allSatisfy {
            $0.analysisPolicySHA256
                == VideoFrameAnalysisPolicy(resolvedRunPlan: currentPlan).sha256
        })
        XCTAssertTrue(zip(receipts, adopted.receipts).allSatisfy {
            $0.analysisArtifactPath != $1.analysisArtifactPath
                && $0.projectRelativePath == $1.projectRelativePath
                && $0.sha256 == $1.sha256
        })
        XCTAssertTrue(oldAnalysisURLs.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
        XCTAssertEqual(
            try controlledURLs.map { try GeometryArtifactStore.sha256(of: $0) },
            originalDigests
        )
        let finalInodes = try controlledURLs.map { url -> UInt64 in
            var status = stat()
            guard lstat(url.path, &status) == 0 else {
                throw POSIXError(.ENOENT)
            }
            return UInt64(status.st_ino)
        }
        XCTAssertEqual(finalInodes, originalInodes)
        XCTAssertNotNil(resumedEvents.stageLog(containing: "Using verified frame analysis"))
        for (index, receipt) in receipts.enumerated() {
            let analysisURL = try paths.resolveProjectRelativePath(
                receipt.analysisArtifactPath
            )
            _ = try VideoFrameAnalysisArtifactStore.load(
                from: analysisURL,
                receipt: receipt,
                expectedPolicy: VideoFrameAnalysisPolicy(resolvedRunPlan: currentPlan),
                expectedClipGroupID: receipt.clipGroupID,
                expectedSourceIndex: index,
                projectPaths: paths
            )
        }
    }

    func testSegmentedMultiVideoResumeReusesCanonicalRawExtraction() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent(
            "CanonicalRawResume.easysplatproj",
            isDirectory: true
        )
        let firstVideo = temp.appendingPathComponent("first-resume.mov")
        let secondVideo = temp.appendingPathComponent("second-resume.mov")
        do {
            try await TestVideoBuilder.writeH264(
                to: firstVideo,
                times: [0, 0.2, 0.4],
                levels: [20, 60, 100]
            )
            try await TestVideoBuilder.writeH264(
                to: secondVideo,
                times: [0, 0.2, 0.4],
                levels: [140, 180, 220]
            )
        } catch TestVideoBuilder.FixtureError.unsupportedCodec(let reason) {
            throw XCTSkip(reason)
        }

        let orderedBytes = try [
            (Data(contentsOf: firstVideo), GeometryArtifactStore.sha256(of: firstVideo)),
            (Data(contentsOf: secondVideo), GeometryArtifactStore.sha256(of: secondVideo)),
        ].sorted { $0.1 > $1.1 }.map(\.0)
        let orderedFirst = temp.appendingPathComponent("ordered-first.mov")
        let orderedSecond = temp.appendingPathComponent("ordered-second.mov")
        try orderedBytes[0].write(to: orderedFirst)
        try orderedBytes[1].write(to: orderedSecond)
        let paths = ProjectPaths(root: projectURL)
        let requestedOptions = RequestedRunOptions(detailProfile: .fast)
        let adopted = try await adoptVideoFixtures(
            [orderedFirst, orderedSecond],
            requestedOptions: requestedOptions,
            paths: paths
        )
        let firstReceipt = adopted.receipts[0]
        let secondReceipt = adopted.receipts[1]
        XCTAssertGreaterThan(firstReceipt.sha256, secondReceipt.sha256)
        let metadata = ProjectMetadata(
            title: "Canonical raw resume",
            input: adopted.input,
            videoInputReceipts: adopted.receipts,
            requestedRunOptions: requestedOptions
        )
        try saveFixtureMetadata(metadata, paths: paths)
        let toolchain = try makeToolchain(root: temp)
        let initial = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                stopAfterStage: .extractFrames
            ),
            tooling: .init(runner: MockSubprocessRunner(scripts: []))
        )

        try await initial.run { _ in }
        let stopped = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(stopped.resolvedRunPlan?.pairingPolicy, .segmentedMixed)
        XCTAssertEqual(stopped.state.stage, .extractFrames)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.framesRawManifestURL.path))
        let rawManifest = try JSONDecoder().decode(
            ExtractedFrameManifest.self,
            from: Data(contentsOf: paths.framesRawManifestURL)
        )
        let canonicalReceipts = try VideoClipIdentityResolver.resolve(
            sourceSHA256s: [firstReceipt.sha256, secondReceipt.sha256],
            pairingPolicy: .segmentedMixed
        ).map { [firstReceipt, secondReceipt][$0.sourceIndex] }
        XCTAssertEqual(
            rawManifest.groups.map(\.sourceProjectRelativePath),
            canonicalReceipts.map(\.projectRelativePath)
        )
        XCTAssertEqual(
            rawManifest.groups.map(\.sourceByteCount),
            canonicalReceipts.map(\.byteCount)
        )
        XCTAssertEqual(
            rawManifest.groups.map(\.sourceSHA256),
            canonicalReceipts.map(\.sha256)
        )
        XCTAssertLessThanOrEqual(
            rawManifest.groups.reduce(0) { $0 + $1.targetCount },
            try XCTUnwrap(stopped.resolvedRunPlan).keyframeBudget
        )
        XCTAssertEqual(
            try initial.validateStageOutput(
                .extractFrames,
                paths: paths,
                metadata: stopped
            ),
            .valid
        )

        let resumedEvents = PipelineEventSink()
        let resumed = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                stopAfterStage: .selectFrames
            ),
            tooling: .init(runner: MockSubprocessRunner(scripts: []))
        )
        try await resumed.run(resumeFrom: .extractFrames) { resumedEvents.append($0) }

        XCTAssertFalse(
            resumedEvents.didStart(.extractFrames),
            "A valid canonical raw manifest must not invoke the decoder again on resume."
        )
        XCTAssertTrue(resumedEvents.didStart(.selectFrames))
        XCTAssertEqual(
            try ProjectMetadataStore.load(from: paths.metadataURL).state.stage,
            .selectFrames
        )
    }

    func testVideoBytesAreBoundBeforeExtractFramesPathReplacement() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent(
            "VideoInputLease.easysplatproj",
            isDirectory: true
        )
        let originalVideo = temp.appendingPathComponent("original.mov")
        let replacementVideo = temp.appendingPathComponent("replacement.mov")
        do {
            try await TestVideoBuilder.writeH264(
                to: originalVideo,
                times: [0, 0.2, 0.4],
                levels: [20, 40, 60]
            )
            try await TestVideoBuilder.writeH264(
                to: replacementVideo,
                times: [0, 0.2, 0.4],
                levels: [180, 200, 220]
            )
        } catch TestVideoBuilder.FixtureError.unsupportedCodec(let reason) {
            throw XCTSkip(reason)
        }

        let paths = ProjectPaths(root: projectURL)
        let requestedOptions = RequestedRunOptions(detailProfile: .fast)
        let adopted = try await adoptVideoFixtures(
            [originalVideo],
            requestedOptions: requestedOptions,
            paths: paths
        )
        let receipt = adopted.receipts[0]
        let controlledVideo = try paths.resolveProjectRelativePath(
            receipt.projectRelativePath
        )
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Video input lease",
                input: adopted.input,
                videoInputReceipts: adopted.receipts,
                requestedRunOptions: requestedOptions
            ),
            to: paths.metadataURL
        )
        let swap = AtomicInputSwapProbe(
            replacement: replacementVideo,
            destination: controlledVideo
        )
        let checkpoint = InputReceiptCheckpointProbe(
            metadataURL: paths.metadataURL,
            stage: .extractFrames
        )
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: try makeToolchain(root: temp),
                candidateRoute: .colmap,
                stopAfterStage: .selectFrames
            ),
            tooling: .init(runner: MockSubprocessRunner(scripts: []))
        )

        try await pipeline.run { event in
            swap.observe(event, at: .extractFrames)
            checkpoint.observe(event)
        }

        XCTAssertTrue(swap.didSwap)
        XCTAssertNil(swap.error)
        XCTAssertEqual(
            checkpoint.inputReceiptDigest,
            try RuntimeInputSnapshotLease.receiptDigest(
                metadata: ProjectMetadataStore.load(from: paths.metadataURL)
            )
        )
        XCTAssertNil(checkpoint.error)
        let manifest = try pipeline.loadSelectedFrameManifest(
            from: paths.framesSelectedManifestURL
        )
        XCTAssertFalse(manifest.isEmpty)
        XCTAssertTrue(manifest.allSatisfy { $0.sourceSHA256 == receipt.sha256 })
    }

    func testPhotoBytesAreBoundBeforeSelectFramesPathReplacement() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent(
            "PhotoInputLease.easysplatproj",
            isDirectory: true
        )
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourcePhotos,
            withIntermediateDirectories: true
        )
        for index in 0..<8 {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(20 + index)
            )
        }
        let paths = ProjectPaths(root: projectURL)
        let controlledMetadata = try saveFixtureMetadata(
            ProjectMetadata(
                title: "Photo input lease",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    detailProfile: .fast,
                    photoSelection: .useAllValidPhotos
                )
            ),
            paths: paths
        )
        let receipt = try XCTUnwrap(controlledMetadata.photoInputReceipts?.first)
        let controlledPhoto = try paths.resolveProjectRelativePath(
            receipt.projectRelativePath
        )
        let replacementPhoto = temp.appendingPathComponent("replacement.jpg")
        try writeTestImage(url: replacementPhoto, value: 240)
        let swap = AtomicInputSwapProbe(
            replacement: replacementPhoto,
            destination: controlledPhoto
        )
        let checkpoint = InputReceiptCheckpointProbe(
            metadataURL: paths.metadataURL,
            stage: .selectFrames
        )
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: try makeToolchain(root: temp),
                candidateRoute: .colmap,
                stopAfterStage: .selectFrames
            ),
            tooling: .init(runner: MockSubprocessRunner(scripts: []))
        )

        try await pipeline.run { event in
            swap.observe(event, at: .selectFrames)
            checkpoint.observe(event)
        }

        XCTAssertTrue(swap.didSwap)
        XCTAssertNil(swap.error)
        XCTAssertEqual(
            checkpoint.inputReceiptDigest,
            try RuntimeInputSnapshotLease.receiptDigest(
                metadata: ProjectMetadataStore.load(from: paths.metadataURL)
            )
        )
        XCTAssertNil(checkpoint.error)
        let manifest = try pipeline.loadSelectedFrameManifest(
            from: paths.framesSelectedManifestURL
        )
        let selected = try XCTUnwrap(manifest.first {
            $0.sourceProjectRelativePath == receipt.projectRelativePath
        })
        XCTAssertEqual(selected.sourceSHA256, receipt.sha256)
    }

    func testFixturePhotoAdmissionPersistsAuthenticatedVisualSelection() async throws {
        let productionPath = PhotoAdmissionPathProbe()
        let fixture = try await makeAuthenticatedPhotoSelectionFixture(
            in: makeTempRoot(),
            name: "VisualAdmission",
            photoCount: 8,
            inputOrdering: .unordered,
            photoSelection: .automatic,
            admissionBudget: 8,
            productionPath: productionPath
        )
        let saved = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)

        XCTAssertNotNil(saved.resolvedRunPlan)
        XCTAssertNotNil(saved.photoSelectionReceipt)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.paths.photoSelectionArtifactURL.path
            )
        )
        let projection = fixture.projection
        XCTAssertEqual(projection.policy, .rankedPrefix)
        XCTAssertEqual(
            projection.rankOrderedReceipts.map(\.source.sha256),
            try PhotoDiversitySelector.rank(
                projection.canonicalReceipts.map(\.analysisEvidence),
                targetCount: projection.canonicalReceipts.count
            ).map(\.sourceSHA256)
        )
        XCTAssertEqual(productionPath.preflightCount, 1)
        XCTAssertEqual(productionPath.adoptionCount, 1)
    }

    func testPhotoSelectionPipelineUnorderedAutomaticUsesAuthenticatedRankedPrefix() async throws {
        let fixture = try await makeAuthenticatedPhotoSelectionFixture(
            in: makeTempRoot(),
            name: "UnorderedAutomaticSelection",
            photoCount: 7,
            inputOrdering: .unordered,
            photoSelection: .automatic,
            admissionBudget: 5
        )
        assertProductionPhotoAdmission(fixture.productionPath)
        var executionPlan = fixture.admissionPlan
        executionPlan.keyframeBudget = 3
        let pipeline = PipelineRunner(
            projectURL: fixture.paths.root,
            config: makePipelineConfig(
                toolchain: fixture.toolchain,
                candidateRoute: .colmap,
                stopAfterStage: .selectFrames,
                resolvedRunPlan: executionPlan
            ),
            tooling: .init(runner: MockSubprocessRunner(scripts: []))
        )

        try await pipeline.run { _ in }

        let manifest = try pipeline.loadSelectedFrameManifest(
            from: fixture.paths.framesSelectedManifestURL
        )
        let expected = Array(fixture.projection.rankOrderedReceipts.prefix(3))
        assertSelectedPhotoMappings(manifest, match: expected)
        XCTAssertEqual(
            expected.map(\.sha256),
            Array(fixture.projection.artifact.retainedSourceSHA256s.prefix(3))
        )
        XCTAssertEqual(expected.map(\.retainedRank), [0, 1, 2])
        let saved = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        XCTAssertEqual(saved.resolvedRunPlan, executionPlan)
        XCTAssertEqual(saved.state.stage, .selectFrames)
    }

    func testPhotoSelectionPipelineContinuousAutomaticUsesEndpointSpacing() async throws {
        let fixture = try await makeAuthenticatedPhotoSelectionFixture(
            in: makeTempRoot(),
            name: "ContinuousAutomaticSelection",
            photoCount: 7,
            inputOrdering: .continuous,
            photoSelection: .automatic,
            admissionBudget: 5
        )
        assertProductionPhotoAdmission(fixture.productionPath)
        var executionPlan = fixture.admissionPlan
        executionPlan.keyframeBudget = 3
        let pipeline = PipelineRunner(
            projectURL: fixture.paths.root,
            config: makePipelineConfig(
                toolchain: fixture.toolchain,
                candidateRoute: .colmap,
                stopAfterStage: .selectFrames,
                resolvedRunPlan: executionPlan
            ),
            tooling: .init(runner: MockSubprocessRunner(scripts: []))
        )

        try await pipeline.run { _ in }

        let manifest = try pipeline.loadSelectedFrameManifest(
            from: fixture.paths.framesSelectedManifestURL
        )
        let canonical = fixture.projection.canonicalReceipts
        XCTAssertEqual(canonical.count, 5)
        let expected = [canonical[0], canonical[2], canonical[4]]
        assertSelectedPhotoMappings(manifest, match: expected)
        XCTAssertEqual(
            expected.map(\.safeDisplayName),
            ["photo-000.jpg", "photo-003.jpg", "photo-006.jpg"]
        )
        XCTAssertEqual(expected.map(\.retainedRank), [0, 2, 4])
    }

    func testPhotoSelectionPipelineUseAllPreservesEveryPhotoAndRejectsShrink() async throws {
        let preserved = try await makeAuthenticatedPhotoSelectionFixture(
            in: makeTempRoot(),
            name: "UseAllPreserved",
            photoCount: 4,
            inputOrdering: .unordered,
            photoSelection: .useAllValidPhotos,
            admissionBudget: 4
        )
        assertProductionPhotoAdmission(preserved.productionPath)
        let preservingPipeline = PipelineRunner(
            projectURL: preserved.paths.root,
            config: makePipelineConfig(
                toolchain: preserved.toolchain,
                candidateRoute: .colmap,
                stopAfterStage: .selectFrames,
                resolvedRunPlan: preserved.admissionPlan
            ),
            tooling: .init(runner: MockSubprocessRunner(scripts: []))
        )

        try await preservingPipeline.run { _ in }

        let preservedManifest = try preservingPipeline.loadSelectedFrameManifest(
            from: preserved.paths.framesSelectedManifestURL
        )
        assertSelectedPhotoMappings(
            preservedManifest,
            match: preserved.projection.canonicalReceipts
        )

        let rejected = try await makeAuthenticatedPhotoSelectionFixture(
            in: makeTempRoot(),
            name: "UseAllShrinkRejected",
            photoCount: 4,
            inputOrdering: .unordered,
            photoSelection: .useAllValidPhotos,
            admissionBudget: 4
        )
        assertProductionPhotoAdmission(rejected.productionPath)
        var shrinkingPlan = rejected.admissionPlan
        shrinkingPlan.keyframeBudget = 3
        let shrinkingPipeline = PipelineRunner(
            projectURL: rejected.paths.root,
            config: makePipelineConfig(
                toolchain: rejected.toolchain,
                candidateRoute: .colmap,
                stopAfterStage: .selectFrames,
                resolvedRunPlan: shrinkingPlan
            ),
            tooling: .init(runner: MockSubprocessRunner(scripts: []))
        )

        await XCTAssertThrowsErrorAsync({
            try await shrinkingPipeline.run { _ in }
        }, errorHandler: { error in
            guard case let .photoSelectionExceedsBudget(selected, maximum)? =
                    error as? PipelineRunner.PipelineError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(selected, 4)
            XCTAssertEqual(maximum, 3)
        })
    }

    func testPhotoSelectionPipelineMixedAutomaticUsesRemainingCapacityAsRankedPrefix() async throws {
        let temp = makeTempRoot()
        let sourcePhotos = try writeVisualPhotoSources(
            in: temp,
            name: "MixedAutomaticPhotos",
            count: 7
        )
        let sourceVideo = temp.appendingPathComponent("mixed-automatic.mov")
        do {
            try await TestVideoBuilder.writeH264(
                to: sourceVideo,
                times: [0, 0.2],
                levels: [40, 200]
            )
        } catch TestVideoBuilder.FixtureError.unsupportedCodec(let reason) {
            throw XCTSkip(reason)
        }
        let paths = ProjectPaths(
            root: temp.appendingPathComponent(
                "MixedAutomaticSelection.easysplatproj",
                isDirectory: true
            )
        )
        let options = RequestedRunOptions(
            detailProfile: .fast,
            inputOrdering: .unordered,
            photoSelection: .automatic
        )
        let requestedInput = InputSpec.mixed(
            videos: [sourceVideo.path],
            photosFolder: sourcePhotos.path
        )
        var plan = resolvedFixturePlan(input: requestedInput, options: options)
        plan.keyframeBudget = 5
        let adopted = try await adoptVideoFixtures(
            [sourceVideo],
            requestedOptions: options,
            paths: paths,
            requestedInput: requestedInput,
            resolvedRunPlan: plan
        )
        var adoption = adopted.adoption
        let productionPath = PhotoAdmissionPathProbe()
        try await adoptPhotoFixtures(
            sourcePhotos,
            plan: plan,
            paths: paths,
            adoption: &adoption,
            productionPath: productionPath
        )
        assertProductionPhotoAdmission(productionPath)
        let saved = ProjectMetadata(
            title: "Mixed automatic selection",
            input: adoption.input,
            videoInputReceipts: try XCTUnwrap(adoption.videoInputReceipts),
            photoInputReceipts: try XCTUnwrap(adoption.photoInputReceipts),
            photoSelectionReceipt: try XCTUnwrap(adoption.photoSelectionReceipt),
            requestedRunOptions: options,
            resolvedRunPlan: plan
        )
        try ProjectMetadataStore.save(saved, to: paths.metadataURL)
        try VideoInputReceiptValidator.validateFiles(metadata: saved, paths: paths)
        try PhotoInputReceiptValidator.validateFiles(metadata: saved, paths: paths)
        let projection = try XCTUnwrap(
            PhotoSelectionProjection.loadVerified(metadata: saved, paths: paths)
        )
        let pipeline = PipelineRunner(
            projectURL: paths.root,
            config: makePipelineConfig(
                toolchain: try makeToolchain(root: temp),
                candidateRoute: .colmap,
                stopAfterStage: .selectFrames,
                resolvedRunPlan: plan
            ),
            tooling: .init(runner: MockSubprocessRunner(scripts: []))
        )

        try await pipeline.run { _ in }

        let manifest = try pipeline.loadSelectedFrameManifest(
            from: paths.framesSelectedManifestURL
        )
        let videoMappings = manifest.filter(\.isVideo)
        let photoMappings = manifest.filter { !$0.isVideo }
        XCTAssertEqual(videoMappings.count, 2)
        XCTAssertEqual(manifest.count, plan.keyframeBudget)
        let remainingCapacity = plan.keyframeBudget - videoMappings.count
        let expectedPhotos = Array(
            projection.rankOrderedReceipts.prefix(remainingCapacity)
        )
        assertSelectedPhotoMappings(photoMappings, match: expectedPhotos)
        XCTAssertEqual(expectedPhotos.map(\.retainedRank), [0, 1, 2])
    }

    func testPhotoSelectionPipelineResumePreservesRetainedRanks() async throws {
        let fixture = try await makeAuthenticatedPhotoSelectionFixture(
            in: makeTempRoot(),
            name: "AutomaticSelectionResume",
            photoCount: 7,
            inputOrdering: .unordered,
            photoSelection: .automatic,
            admissionBudget: 5
        )
        assertProductionPhotoAdmission(fixture.productionPath)
        var executionPlan = fixture.admissionPlan
        executionPlan.keyframeBudget = 3
        let firstPipeline = PipelineRunner(
            projectURL: fixture.paths.root,
            config: makePipelineConfig(
                toolchain: fixture.toolchain,
                candidateRoute: .colmap,
                stopAfterStage: .selectFrames,
                resolvedRunPlan: executionPlan
            ),
            tooling: .init(runner: MockSubprocessRunner(scripts: []))
        )
        try await firstPipeline.run { _ in }
        let firstManifest = try firstPipeline.loadSelectedFrameManifest(
            from: fixture.paths.framesSelectedManifestURL
        )
        let firstMetadata = try ProjectMetadataStore.load(
            from: fixture.paths.metadataURL
        )
        let firstSelectionReceipt = try XCTUnwrap(firstMetadata.photoSelectionReceipt)
        let firstSelectionBytes = try Data(
            contentsOf: fixture.paths.photoSelectionArtifactURL
        )
        var firstSelectionStatus = stat()
        XCTAssertEqual(
            lstat(
                fixture.paths.photoSelectionArtifactURL.path,
                &firstSelectionStatus
            ),
            0
        )

        let resumedPipeline = PipelineRunner(
            projectURL: fixture.paths.root,
            config: makePipelineConfig(
                toolchain: fixture.toolchain,
                candidateRoute: .colmap,
                stopAfterStage: .selectFrames,
                resolvedRunPlan: executionPlan
            ),
            tooling: .init(runner: MockSubprocessRunner(scripts: []))
        )
        try await resumedPipeline.run(resumeFrom: .extractFrames) { _ in }
        let resumedManifest = try resumedPipeline.loadSelectedFrameManifest(
            from: fixture.paths.framesSelectedManifestURL
        )

        XCTAssertEqual(resumedManifest, firstManifest)
        assertSelectedPhotoMappings(
            resumedManifest,
            match: Array(fixture.projection.rankOrderedReceipts.prefix(3))
        )
        XCTAssertEqual(resumedManifest.compactMap(\.photoRetainedRank), [0, 1, 2])
        let resumedMetadata = try ProjectMetadataStore.load(
            from: fixture.paths.metadataURL
        )
        XCTAssertEqual(resumedMetadata.photoSelectionReceipt, firstSelectionReceipt)
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.photoSelectionArtifactURL),
            firstSelectionBytes
        )
        var resumedSelectionStatus = stat()
        XCTAssertEqual(
            lstat(
                fixture.paths.photoSelectionArtifactURL.path,
                &resumedSelectionStatus
            ),
            0
        )
        XCTAssertEqual(resumedSelectionStatus.st_dev, firstSelectionStatus.st_dev)
        XCTAssertEqual(resumedSelectionStatus.st_ino, firstSelectionStatus.st_ino)
        XCTAssertEqual(
            resumedSelectionStatus.st_mtimespec.tv_sec,
            firstSelectionStatus.st_mtimespec.tv_sec
        )
        XCTAssertEqual(
            resumedSelectionStatus.st_mtimespec.tv_nsec,
            firstSelectionStatus.st_mtimespec.tv_nsec
        )
        _ = try XCTUnwrap(
            PhotoSelectionProjection.loadVerified(
                metadata: resumedMetadata,
                paths: fixture.paths
            )
        )
    }

    func testResumeRejectsCheckpointBoundToDifferentInputReceipts() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent(
            "CheckpointInputReceiptMismatch.easysplatproj",
            isDirectory: true
        )
        let sourceVideo = temp.appendingPathComponent("checkpoint-source.mov")
        do {
            try await TestVideoBuilder.writeH264(
                to: sourceVideo,
                times: [0, 0.2, 0.4],
                levels: [20, 40, 60]
            )
        } catch TestVideoBuilder.FixtureError.unsupportedCodec(let reason) {
            throw XCTSkip(reason)
        }

        let paths = ProjectPaths(root: projectURL)
        let requestedOptions = RequestedRunOptions(detailProfile: .fast)
        let resolvedPlan = RunPlanResolver.resolve(
            requestedOptions: requestedOptions,
            input: .video(files: [sourceVideo.path]),
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: .none
        )
        let (_, receipt) = try TestFileBuilder.writeControlledVideoReceipt(
            paths: paths,
            bytes: Data(contentsOf: sourceVideo),
            safeDisplayName: sourceVideo.lastPathComponent,
            analysisPolicy: VideoFrameAnalysisPolicy(resolvedRunPlan: resolvedPlan)
        )
        let metadata = ProjectMetadata(
            title: "Checkpoint input receipt mismatch",
            input: .video(files: [receipt.projectRelativePath]),
            videoInputReceipts: [receipt],
            requestedRunOptions: requestedOptions,
            resolvedRunPlan: resolvedPlan,
            state: PipelineState(stage: .extractFrames, lastError: nil),
            checkpoint: PipelineCheckpoint(
                stage: .extractFrames,
                inputReceiptDigest: String(repeating: "0", count: 64)
            ),
            lastRunStartedAt: Date(timeIntervalSince1970: 1)
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: try makeToolchain(root: temp),
                candidateRoute: .colmap,
                stopAfterStage: .selectFrames
            ),
            tooling: .init(runner: MockSubprocessRunner(scripts: []))
        )

        do {
            try await pipeline.run { _ in }
            XCTFail("Expected checkpoint receipt mismatch rejection")
        } catch let error as RuntimeInputSnapshotError {
            XCTAssertEqual(error, .invalidMetadata)
        }
    }

    func testMultiVideoAnalysisRecoversBudgetAfterSparseClipSaturates() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent(
            "RedistributedVideoSelection.easysplatproj",
            isDirectory: true
        )
        let denseVideo = temp.appendingPathComponent("dense.mov")
        let sparseVideo = temp.appendingPathComponent("sparse.mov")
        let denseTimes = (0..<120).map { Double($0) / 12 }
        do {
            try await TestVideoBuilder.writeH264(
                to: denseVideo,
                times: denseTimes,
                levels: denseTimes.indices.map { UInt8(40 + $0 % 180) },
                expectedFrameRate: 12
            )
            try await TestVideoBuilder.writeH264(
                to: sparseVideo,
                times: [0, 90],
                levels: [80, 120],
                expectedFrameRate: 30
            )
        } catch TestVideoBuilder.FixtureError.unsupportedCodec(let reason) {
            throw XCTSkip(reason)
        }
        let paths = ProjectPaths(root: projectURL)
        let requestedOptions = RequestedRunOptions(detailProfile: .fast)
        let adopted = try await adoptVideoFixtures(
            [denseVideo, sparseVideo],
            requestedOptions: requestedOptions,
            paths: paths
        )
        let denseReceipt = adopted.receipts[0]
        let sparseReceipt = adopted.receipts[1]

        let metadata = ProjectMetadata(
            title: "Redistributed selection",
            input: adopted.input,
            videoInputReceipts: adopted.receipts,
            requestedRunOptions: requestedOptions
        )
        try saveFixtureMetadata(metadata, paths: paths)
        let toolchain = try makeToolchain(root: temp)
        let events = PipelineEventSink()
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                stopAfterStage: .selectFrames
            ),
            tooling: .init(runner: MockSubprocessRunner(scripts: []))
        )

        try await pipeline.run { events.append($0) }

        let manifest = try pipeline.loadSelectedFrameManifest(
            from: paths.framesSelectedManifestURL
        )
        XCTAssertEqual(manifest.filter {
            $0.groupId == "video_sha256_\(denseReceipt.sha256)"
        }.count, 118)
        XCTAssertEqual(manifest.filter {
            $0.groupId == "video_sha256_\(sparseReceipt.sha256)"
        }.count, 2)
        XCTAssertEqual(manifest.count, 120)
        let extractionProgress = events.progressFractions(for: .extractFrames)
        XCTAssertTrue(zip(extractionProgress, extractionProgress.dropFirst()).allSatisfy {
            $1 >= $0
        })
        XCTAssertEqual(extractionProgress.last ?? -1, 1, accuracy: 0.000_001)
    }

    func testPipelineSuccessWithMapper() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<100 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(metadata, paths: paths)

        let toolchain = try makeToolchain(root: temp)
        let runStartProbe = RunStartMarkerProbe()
        let powerAssertion = RecordingPowerAssertion()

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                let loaded = try? ProjectMetadataStore.load(from: paths.metadataURL)
                runStartProbe.record(observed: loaded?.lastRunStartedAt != nil)
                XCTAssertEqual(powerAssertion.active, 1, "The assertion must still be active while subprocess work is running.")
                try? self.writeFeatureDatabase(for: args)
            }),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["local_vocab_retriever"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try? self.writeVocabularyOutput(for: $0, connectQueries: true) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try? self.writeVerifiedPairResults(for: $0) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                stderrLines: [
                    "Retriangulation and Global bundle adjustment",
                    "Retriangulation and Global bundle adjustment",
                ],
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--Mapper.ba_global_frames_ratio", in: args), "1.4")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_global_points_ratio", in: args), "1.4")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_local_max_refinements", in: args), "2")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_global_max_refinements", in: args), "5")
                    XCTAssertEqual(self.value(for: "--Mapper.random_seed", in: args), "42")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_refine_focal_length", in: args), "1")
                    let imageNames = self.selectedImageNames(in: paths)
                    let sparseRoot = paths.colmapSparseURL
                    try? self.writeSparseModel(
                        at: sparseRoot.appendingPathComponent("0", isDirectory: true),
                        imageNames: Array(imageNames.prefix(80))
                    )
                    try? self.writeSparseModel(
                        at: sparseRoot.appendingPathComponent("1", isDirectory: true),
                        imageNames: imageNames
                    )
                }
            ),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "Unreadable model"), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 100 / 100\nPoints: 20\nObservations: 2000\nMean track length: 100.0\nMean reprojection error: 0.0\n", stderr: ""), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, candidateRoute: .colmap, skipTraining: true),
            tooling: .init(runner: runner),
            powerAssertion: powerAssertion
        )

        let events = PipelineEventSink()
        try await pipeline.run { events.append($0) }

        let launched = zip(runner.calls, runner.environments).map {
            (command: $0.0.1.first, environment: $0.1)
        }
        XCTAssertEqual(
            launched.first(where: { $0.command == "feature_extractor" })?
                .environment["OMP_NUM_THREADS"],
            "12"
        )
        XCTAssertEqual(
            launched.first(where: { $0.command == "matches_importer" })?
                .environment["OMP_NUM_THREADS"],
            "8"
        )
        XCTAssertEqual(
            launched.first(where: { $0.command == "local_vocab_retriever" })?
                .environment["OMP_NUM_THREADS"],
            "8"
        )
        XCTAssertNil(
            launched.first(where: { $0.command == "mapper" })?
                .environment["OMP_NUM_THREADS"]
        )
        XCTAssertTrue(
            launched.filter { $0.command == "model_analyzer" }
                .allSatisfy { $0.environment["OMP_NUM_THREADS"] == nil }
        )

        XCTAssertEqual(powerAssertion.begun, 1, "A successful run holds exactly one idle-sleep assertion.")
        XCTAssertEqual(powerAssertion.released, 1, "A successful run must release the idle-sleep assertion.")
        XCTAssertEqual(powerAssertion.active, 0)

        XCTAssertTrue(runStartProbe.wasObserved, "Expected lastRunStartedAt to be set before subprocess work starts.")
        let finalMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertNil(finalMetadata.lastRunStartedAt, "Successful runs should clear lastRunStartedAt.")
        let selectedCount = selectedImageNames(in: paths).count
        let geometry = try GeometryArtifactStore.load(
            from: paths.geometryManifestURL,
            projectPaths: paths
        )
        XCTAssertEqual(geometry.registeredViewCount, selectedCount)
        XCTAssertEqual(geometry.totalViewCount, selectedCount)
        XCTAssertTrue(geometry.solverVersion.hasPrefix("colmap;"))
        XCTAssertEqual(geometry.residualProvenance, "colmap-text-tracks-v1")
        XCTAssertEqual(geometry.medianPixelResidual, 0, accuracy: 0.000_001)
        XCTAssertEqual(geometry.p90PixelResidual, 0, accuracy: 0.000_001)
        let artifactMappingDuration = try XCTUnwrap(
            geometry.timings[PipelineStage.sfmMapping.rawValue]
        )
        let finalMappingDuration = try XCTUnwrap(
            finalMetadata.stageTimings?.first(where: { $0.stage == .sfmMapping })?.durationSeconds
        )
        XCTAssertGreaterThan(artifactMappingDuration, 0)
        XCTAssertGreaterThan(finalMappingDuration, artifactMappingDuration)
        XCTAssertGreaterThan(
            try XCTUnwrap(geometry.timings["orientation_estimation_seconds"]),
            0
        )
        XCTAssertNil(geometry.timings["orientation_seconds"])
        XCTAssertEqual(geometry.schemaVersion, GeometryArtifact.currentSchemaVersion)
        XCTAssertEqual(geometry.modelVersion, "none")
        XCTAssertEqual(geometry.provenance.toolchainVersion, "Toolchain")
        XCTAssertEqual(geometry.provenance.solver.identifier, "colmap")
        XCTAssertNil(geometry.provenance.runtime)
        XCTAssertNil(geometry.provenance.model)
        XCTAssertEqual(
            geometry.workerExecution.resolvedBudget,
            try XCTUnwrap(finalMetadata.resolvedRunPlan).geometryWorkerBudget
        )
        XCTAssertEqual(
            geometry.workerExecution.featureExtractionInvocations.map(\.command),
            [.featureExtractor]
        )
        XCTAssertEqual(
            geometry.workerExecution.matchingInvocations.map(\.command),
            [.matchesImporter]
        )
        XCTAssertEqual(
            geometry.workerExecution.vocabularyRetrievalInvocations.map(\.command),
            [.localVocabularyRetriever]
        )
        XCTAssertEqual(
            geometry.workerExecution.mappingAndRefinementInvocations.map(\.command),
            [.mapper, .modelAnalyzer, .modelAnalyzer]
        )
        XCTAssertEqual(
            geometry.workerExecution.mappingAndRefinementInvocations.map(\.succeeded),
            [true, false, true]
        )
        XCTAssertEqual(
            geometry.workerExecution.videoSourceAnalysis,
            VideoSourceAnalysisExecutionEvidence(
                videoSourceCount: 0,
                startedAnalysisTaskCount: 0,
                peakInFlightAnalysisTaskCount: 0
            )
        )
        XCTAssertEqual(
            try GeometryWorkerExecutionArtifactStore.load(
                from: paths.workerExecutionURL,
                expectedBudget: geometry.workerExecution.resolvedBudget,
                projectPaths: paths
            ),
            geometry.workerExecution
        )
        XCTAssertEqual(geometry.pairGraph.status, .measured)
        XCTAssertTrue(geometry.pairGraph.retrievalWasScheduled)
        XCTAssertTrue(geometry.pairGraph.usedLocalVocabularyRetrieval)
        let pairGraph = try XCTUnwrap(geometry.pairGraph.measurement)
        let pairEvidence = try PairGraphEvidenceStore.load(
            from: paths.pairGraphEvidenceURL,
            projectPaths: paths
        )
        XCTAssertEqual(pairGraph.connectedComponentCount, 1)
        XCTAssertEqual(pairGraph.isolatedViewCount, 0)
        XCTAssertEqual(
            pairGraph.articulationViewCount,
            pairEvidence.acceptedInspection.articulationViewCount
        )
        XCTAssertEqual(
            pairGraph.biconnectedBlockCount,
            pairEvidence.acceptedInspection.biconnectedBlockCount
        )
        XCTAssertEqual(
            pairGraph.largestBiconnectedBlockViewCount,
            pairEvidence.acceptedInspection.largestBiconnectedBlockViewCount
        )
        XCTAssertEqual(
            pairGraph.secondLargestBiconnectedBlockViewCount,
            pairEvidence.acceptedInspection.secondLargestBiconnectedBlockViewCount
        )
        XCTAssertGreaterThan(pairGraph.retrievalPairCount, 0)
        XCTAssertEqual(geometry.mapping.modelCount, 2)
        XCTAssertEqual(geometry.mapping.largestModelRegisteredViewCount, 100)
        XCTAssertEqual(geometry.mapping.secondLargestModelRegisteredViewCount, 80)
        XCTAssertEqual(geometry.mapping.unionRegisteredViewCount, 100)
        XCTAssertEqual(geometry.mapping.attemptCount, 1)
        XCTAssertEqual(geometry.mapping.acceptedRefinementKind, .incrementalGlobal)
        XCTAssertEqual(geometry.mapping.acceptedRefinementInvocationCount, 2)
        XCTAssertEqual(
            geometry.mapping.incrementalCadence,
            IncrementalMappingCadenceArtifact(
                localMaxRefinements: 2,
                globalFramesRatio: 1.4,
                globalPointsRatio: 1.4,
                globalMaxRefinements: 5
            )
        )
        XCTAssertNil(geometry.mapping.fallbackReason)
        XCTAssertEqual(geometry.canonicalOrientation.status, .unresolved)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: paths.colmapSparseURL.path)
                .contains(where: { $0.hasPrefix(".orientation-candidate-") })
        )
        XCTAssertEqual(
            try GeometryArtifactStore.load(
                from: paths.geometryManifestURL,
                projectPaths: paths,
                expectedInput: finalMetadata.input
            ),
            geometry
        )
        XCTAssertNotNil(events.stageLog(containing: "SfM backend: COLMAP mapper."))
        XCTAssertNotNil(events.stageLog(containing: "Could not inspect COLMAP model 0"))
        XCTAssertNotNil(events.stageLog(containing: "Selected COLMAP model 1 (100/100 registered views)."))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: paths.colmapSparseURL.path).sorted(),
            ["0"]
        )
        let analyzedModels = runner.calls
            .filter { $0.1.first == "model_analyzer" }
            .compactMap { self.value(for: "--path", in: $0.1) }
            .map { URL(fileURLWithPath: $0).lastPathComponent }
        XCTAssertEqual(analyzedModels, ["0", "1"])
        let selectedManifest = try String(contentsOf: paths.framesSelectedManifestURL, encoding: .utf8)
        XCTAssertFalse(selectedManifest.contains("sourcePath"))
    }

    func testMapperPublishesSecondaryModelWhenPreferredAnalyzerCandidateHasHighMeasuredResiduals() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent(
            "ResidualValidatedMapperSelection.easysplatproj",
            isDirectory: true
        )
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourcePhotos,
            withIntermediateDirectories: true
        )
        for index in 0..<10 {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(index)
            )
        }

        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(
            ProjectMetadata(
                title: "Residual-validated mapper selection",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    detailProfile: .fast,
                    inputOrdering: .unordered,
                    photoSelection: .useAllValidPhotos
                )
            ),
            paths: paths
        )
        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try self.writeFeatureDatabase(for: $0) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try self.writeVerifiedPairResults(for: $0) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                stdoutLines: ["Retriangulation and Global bundle adjustment"],
                onRun: { _ in
                    let imageNames = self.selectedImageNames(in: paths)
                    let preferred = paths.colmapSparseURL.appendingPathComponent(
                        "0",
                        isDirectory: true
                    )
                    try self.writeSparseModel(at: preferred, imageNames: imageNames)
                    try self.makeSparseModelHighResidual(at: preferred)
                    try self.writeSparseModel(
                        at: paths.colmapSparseURL.appendingPathComponent("1", isDirectory: true),
                        imageNames: Array(imageNames.prefix(9))
                    )
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: 9 / 10\nPoints: 20\nObservations: 180\nMean track length: 9.0\nMean reprojection error: 0.5\n",
                    stderr: ""
                )
            ),
        ])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                skipTraining: true
            ),
            tooling: .init(runner: runner)
        )
        let events = PipelineEventSink()

        try await pipeline.run { events.append($0) }

        let canonicalModel = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        let residuals = try ColmapResidualAnalyzer.analyze(modelDirectory: canonicalModel)
        XCTAssertEqual(residuals.registeredViewCount, 9)
        XCTAssertEqual(residuals.medianPixelResidual, 0, accuracy: 0.000_001)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: paths.colmapSparseURL.path),
            ["0"]
        )
        XCTAssertNotNil(events.stageLog(containing: "Could not inspect COLMAP model 0"))
        XCTAssertNotNil(events.stageLog(containing: "Selected COLMAP model 1 (9/10 registered views)."))
    }

    func testOrderedColmapMatchingAddsVerifiedLoopPairs() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("OrderedLoops.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<30 {
            try writeRetrievalTestImage(
                url: sourcePhotos.appendingPathComponent(String(format: "img_%03d.jpg", index)),
                index: index
            )
        }

        let metadata = ProjectMetadata(
            title: "Ordered loops",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .fast,
                inputOrdering: .continuous,
                photoSelection: .useAllValidPhotos
            )
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(metadata, paths: paths)
        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { try? self.writeFeatureDatabase(for: $0) }),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["local_vocab_retriever"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: {
                    try? self.writeVocabularyOutput(
                        for: $0,
                        pairLines: ["frame_000000.jpg frame_000029.jpg"]
                    )
                }
            ),
            .init(path: toolchain.colmap.path, argsPrefix: ["matches_importer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let path = self.value(for: "--match_list_path", in: args),
                      let pairs = try? String(contentsOfFile: path, encoding: .utf8) else {
                    return XCTFail("Loop pair list was not readable")
                }
                XCTAssertTrue(pairs.contains("frame_000000.jpg frame_000029.jpg"))
                try? self.writeVerifiedPairResults(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), stdoutLines: ["Retriangulation and Global bundle adjustment"], onRun: { args in
                XCTAssertEqual(self.value(for: "--Mapper.ba_global_frames_ratio", in: args), "4.0")
                XCTAssertEqual(self.value(for: "--Mapper.ba_global_points_ratio", in: args), "4.0")
                XCTAssertEqual(self.value(for: "--Mapper.ba_local_max_refinements", in: args), "1")
                try? self.writeSparseModel(at: projectURL)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 30 / 30\nPoints: 20\nObservations: 600\nMean track length: 30.0\n", stderr: ""), onRun: nil),
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                skipTraining: true
            ),
            tooling: .init(runner: runner)
        )
        try await pipeline.run { _ in }

        let commands = runner.calls.compactMap { $0.1.first }
        XCTAssertTrue(commands.contains("local_vocab_retriever"))
        XCTAssertTrue(commands.contains("matches_importer"))
        let geometry = try GeometryArtifactStore.load(
            from: paths.geometryManifestURL,
            projectPaths: paths
        )
        let pairGraph = try XCTUnwrap(geometry.pairGraph.measurement)
        XCTAssertEqual(pairGraph.localPairCount, 119)
        XCTAssertEqual(pairGraph.loopRevisitPairCount, 1)
        let evidence = try PairGraphEvidenceStore.loadVerified(
            from: paths.pairGraphEvidenceURL,
            expectedImageNames: geometry.orderedImageNames,
            databaseURL: paths.colmapDatabaseURL,
            projectPaths: paths
        )
        let resolvedPlan = try XCTUnwrap(
            ProjectMetadataStore.load(from: paths.metadataURL).resolvedRunPlan
        )
        XCTAssertEqual(evidence.planBinding, PairGraphPlanBinding(resolvedPlan))
        XCTAssertEqual(evidence.attempts.last?.retrieval?.directedPairLines, [
            "frame_000000.jpg frame_000029.jpg",
        ])
        XCTAssertNoThrow(try PairGraphEvidenceStore.validateSchedule(
            evidence,
            resolvedPlan: resolvedPlan,
            groups: [ColmapPairGroup(imageNames: evidence.imageNames, isVideo: false)]
        ))
    }

    func testFaissCrashRetriesExactMatchingWithoutReextractingFeatures() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("FaissRecovery.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<30 {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(index)
            )
        }

        let metadata = ProjectMetadata(
            title: "FAISS recovery",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .walkthrough,
                detailProfile: .fast,
                inputOrdering: .continuous,
                photoSelection: .useAllValidPhotos
            )
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(metadata, paths: paths)
        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    do {
                        try self.writeFeatureDatabase(for: args)
                    } catch {
                        XCTFail("Could not create COLMAP database fixture: \(error)")
                    }
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["local_vocab_retriever"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try? self.writeVocabularyOutput(for: $0) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(
                    exitCode: SIGSEGV,
                    terminationReason: .uncaughtSignal,
                    stdout: "",
                    stderr: "segmentation fault"
                ),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: args), "0")
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["local_vocab_retriever"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try? self.writeVocabularyOutput(for: $0) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: args), "1")
                    try? self.writeVerifiedPairResults(for: args)
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                stdoutLines: ["Retriangulation and Global bundle adjustment"],
                onRun: { _ in try? self.writeSparseModel(at: projectURL) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: 30 / 30\nPoints: 20\nObservations: 600\nMean track length: 30.0\nMean reprojection error: 0.5\n",
                    stderr: ""
                ),
                onRun: nil
            ),
        ])
        let events = PipelineEventSink()
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                skipTraining: true
            ),
            tooling: .init(runner: runner)
        )

        do {
            try await pipeline.run { events.append($0) }
        } catch {
            XCTFail("Pipeline failed after calls \(runner.calls): \(error)")
            return
        }

        let commands = runner.calls.compactMap { $0.1.first }
        XCTAssertEqual(commands.filter { $0 == "feature_extractor" }.count, 1)
        XCTAssertEqual(commands.filter { $0 == "local_vocab_retriever" }.count, 1)
        XCTAssertEqual(commands.filter { $0 == "matches_importer" }.count, 2)
        XCTAssertNotNil(events.stageLog(containing: "preserving features and retrying with exact matching"))
        let geometry = try GeometryArtifactStore.load(
            from: paths.geometryManifestURL,
            projectPaths: paths
        )
        XCTAssertEqual(geometry.mapping.attemptCount, 1)
        XCTAssertEqual(geometry.mapping.fallbackReason, "exact descriptor matching")
        let evidence = try PairGraphEvidenceStore.load(
            from: paths.pairGraphEvidenceURL,
            projectPaths: paths
        )
        XCTAssertEqual(
            evidence.attempts[0].scheduledPairs,
            evidence.attempts[1].scheduledPairs
        )
    }

    func testRejectedExactMatcherAttemptIsPersistedBeforeTerminalGraphFailure() async throws {
        let temp = makeTempRoot()
        let fixture = try makePhotoRecoveryProject(
            in: temp,
            name: "RejectedExactEvidence",
            photoCount: 8
        )
        let run = makePhotoRecoveryPipeline(
            projectURL: fixture.projectURL,
            toolchain: fixture.toolchain,
            scripts: [
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["feature_extractor"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { try self.writeFeatureDatabase(for: $0) }
                ),
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["matches_importer"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { arguments in
                        XCTAssertEqual(
                            self.value(
                                for: "--SiftMatching.cpu_brute_force_matcher",
                                in: arguments
                            ),
                            "0"
                        )
                        try self.writeVerifiedPairResults(
                            for: arguments,
                            verifiedRows: 0
                        )
                    }
                ),
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["matches_importer"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { arguments in
                        XCTAssertEqual(
                            self.value(
                                for: "--SiftMatching.cpu_brute_force_matcher",
                                in: arguments
                            ),
                            "1"
                        )
                        try self.writeVerifiedPairResults(
                            for: arguments,
                            verifiedRows: 0
                        )
                    }
                ),
            ]
        )

        do {
            try await run.pipeline.run { _ in }
            XCTFail("Expected the exact matcher graph to remain disconnected")
        } catch {
            guard let failure = error as? CaptureConnectionFailure else {
                return XCTFail("Expected typed exhausted capture evidence, got \(error)")
            }
            XCTAssertEqual(failure.pairingPolicy, .unorderedRetrieval)
            XCTAssertEqual(failure.selectedViewCount, 8)
            XCTAssertEqual(failure.attempt.matcher, .exact)
            XCTAssertEqual(failure.attempt.recoveryLevel, .normal)
            XCTAssertEqual(failure.attempt.scheduledPairCount, 28)
            XCTAssertEqual(failure.attempt.attemptedPairCount, 28)
            XCTAssertEqual(failure.attempt.spatiallyVerifiedPairCount, 0)
            XCTAssertEqual(failure.connectedComponentCount, 8)
            XCTAssertEqual(failure.isolatedViewCount, 8)
        }

        XCTAssertEqual(
            run.runner.calls.filter { $0.1.first == "matches_importer" }.count,
            2
        )
        let state = try PairGraphRecoveryStore.loadBound(
            from: fixture.paths.pairGraphRecoveryURL,
            expectedImageNames: selectedImageNames(in: fixture.paths),
            projectPaths: fixture.paths
        )
        XCTAssertEqual(state.attempts.map(\.artifact.matcher), [.faiss, .exact])
        XCTAssertEqual(state.attempts.map(\.artifact.outcome), [.rejected, .rejected])
        XCTAssertEqual(
            state.matchingDurationSeconds,
            state.attempts.reduce(0) { $0 + $1.artifact.durationSeconds },
            accuracy: 1e-12
        )
        XCTAssertEqual(state.attempts.map(\.artifact.attemptedPairCount), [28, 28])
        XCTAssertEqual(state.attempts.map(\.artifact.rawMatchedPairCount), [28, 28])
        XCTAssertEqual(state.attempts.map(\.artifact.spatiallyVerifiedPairCount), [0, 0])
    }

    func testDescriptorlessSingletonDoesNotTriggerMatchingRecovery() async throws {
        let temp = makeTempRoot()
        let fixture = try makePhotoRecoveryProject(
            in: temp,
            name: "DescriptorlessSingleton"
        )
        let run = makePhotoRecoveryPipeline(
            projectURL: fixture.projectURL,
            toolchain: fixture.toolchain,
            scripts: [
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["feature_extractor"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { arguments in
                        try self.writeFeatureDatabase(for: arguments)
                        try self.markLastImageDescriptorless(for: arguments)
                    }
                ),
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["matches_importer"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { arguments in
                        XCTAssertEqual(
                            self.value(
                                for: "--SiftMatching.cpu_brute_force_matcher",
                                in: arguments
                            ),
                            "0"
                        )
                        try self.writeVerifiedPairResults(for: arguments)
                    }
                ),
            ] + successfulMappingScripts(
                colmapPath: fixture.toolchain.colmap.path,
                projectURL: fixture.projectURL,
                registeredViews: 59,
                totalViews: 60,
                pointCount: 20
            )
        )
        let events = PipelineEventSink()

        try await run.pipeline.run { events.append($0) }

        XCTAssertEqual(run.runner.calls.count { $0.1.first == "feature_extractor" }, 1)
        XCTAssertEqual(run.runner.calls.count { $0.1.first == "matches_importer" }, 1)
        XCTAssertNotNil(events.stageLog(containing: "had no usable descriptors"))
        let evidence = try PairGraphEvidenceStore.loadVerified(
            from: fixture.paths.pairGraphEvidenceURL,
            expectedImageNames: selectedImageNames(in: fixture.paths),
            databaseURL: fixture.paths.colmapDatabaseURL,
            projectPaths: fixture.paths
        )
        XCTAssertEqual(evidence.attempts.count, 1)
        XCTAssertEqual(evidence.acceptedInspection.connectedComponentCount, 2)
        XCTAssertEqual(evidence.acceptedInspection.isolatedViewCount, 1)
        XCTAssertEqual(evidence.acceptedInspection.descriptorlessViewCount, 1)
        let geometry = try GeometryArtifactStore.load(
            from: fixture.paths.geometryManifestURL,
            projectPaths: fixture.paths
        )
        XCTAssertEqual(geometry.registeredViewCount, 59)
        XCTAssertEqual(geometry.pairGraph.measurement?.descriptorlessViewCount, 1)
        XCTAssertEqual(
            geometry.pairGraph.measurement?.articulationViewCount,
            evidence.acceptedInspection.articulationViewCount
        )
        XCTAssertEqual(
            geometry.pairGraph.measurement?.biconnectedBlockCount,
            evidence.acceptedInspection.biconnectedBlockCount
        )

        var tampered = evidence
        let descriptorBearingViewCount = tampered.imageNames.count
            - tampered.acceptedInspection.descriptorlessViewCount
        if tampered.acceptedInspection.biconnectedBlockCount == 1 {
            tampered.acceptedInspection.articulationViewCount = 1
            tampered.acceptedInspection.biconnectedBlockCount = 2
            tampered.acceptedInspection.largestBiconnectedBlockViewCount
                = descriptorBearingViewCount - 1
            tampered.acceptedInspection.secondLargestBiconnectedBlockViewCount = 2
        } else {
            tampered.acceptedInspection.articulationViewCount = 0
            tampered.acceptedInspection.biconnectedBlockCount = 1
            tampered.acceptedInspection.largestBiconnectedBlockViewCount
                = descriptorBearingViewCount
            tampered.acceptedInspection.secondLargestBiconnectedBlockViewCount = 0
        }
        try PairGraphEvidenceStore.save(
            tampered,
            to: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
        XCTAssertThrowsError(try PairGraphEvidenceStore.loadVerified(
            from: fixture.paths.pairGraphEvidenceURL,
            expectedImageNames: selectedImageNames(in: fixture.paths),
            databaseURL: fixture.paths.colmapDatabaseURL,
            projectPaths: fixture.paths
        ))
    }

    func testAutomaticPhotoSelectionAcceptsDominantGraphWithoutExactRecovery() async throws {
        try await assertPhotoSelectionAcceptsDominantGraphWithoutExactRecovery(
            .automatic,
            projectName: "AutomaticDominantGraph"
        )
    }

    func testUseAllPhotoSelectionAcceptsDominantGraphWithoutExactRecovery() async throws {
        try await assertPhotoSelectionAcceptsDominantGraphWithoutExactRecovery(
            .useAllValidPhotos,
            projectName: "UseAllDominantGraph"
        )
    }

    private func assertPhotoSelectionAcceptsDominantGraphWithoutExactRecovery(
        _ photoSelection: PhotoSelection,
        projectName: String
    ) async throws {
        let temp = makeTempRoot()
        let fixture = try makePhotoRecoveryProject(
            in: temp,
            name: projectName,
            photoSelection: photoSelection
        )
        let run = makePhotoRecoveryPipeline(
            projectURL: fixture.projectURL,
            toolchain: fixture.toolchain,
            scripts: [
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["feature_extractor"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { try self.writeFeatureDatabase(for: $0) }
                ),
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["matches_importer"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { try self.writeFiftyNinePlusOneFaissResults(for: $0) }
                ),
            ] + successfulMappingScripts(
                colmapPath: fixture.toolchain.colmap.path,
                projectURL: fixture.projectURL,
                registeredViews: 59,
                totalViews: 60,
                pointCount: 20
            )
        )
        let events = PipelineEventSink()

        try await run.pipeline.run { events.append($0) }

        XCTAssertEqual(run.runner.calls.count { $0.1.first == "feature_extractor" }, 1)
        XCTAssertEqual(run.runner.calls.count { $0.1.first == "matches_importer" }, 1)
        XCTAssertNotNil(events.stageLog(containing: "had no verified overlap"))
        let evidence = try PairGraphEvidenceStore.load(
            from: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
        XCTAssertEqual(evidence.attempts.count, 1)
        XCTAssertEqual(evidence.acceptedInspection.connectedComponentCount, 2)
        XCTAssertEqual(evidence.acceptedInspection.isolatedViewCount, 1)
        XCTAssertEqual(evidence.acceptedInspection.descriptorlessViewCount, 0)
        XCTAssertTrue(evidence.fallbackReasons.isEmpty)
        let geometry = try GeometryArtifactStore.load(
            from: fixture.paths.geometryManifestURL,
            projectPaths: fixture.paths
        )
        XCTAssertEqual(geometry.registeredViewCount, 59)
        XCTAssertEqual(geometry.totalViewCount, 60)
    }

    func testUnsafeExpandedFaissMappingFallsBackWithoutTouchingExternalData() async throws {
        let temp = makeTempRoot()
        let fixture = try makePhotoRecoveryProject(
            in: temp,
            name: "UnsafeExpandedFaissMappingFallback",
            inputOrdering: .continuous
        )
        let unsafeSparseRoot = temp.appendingPathComponent(
            "ExternalSparseOutput",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: unsafeSparseRoot,
            withIntermediateDirectories: true
        )
        let sentinel = unsafeSparseRoot.appendingPathComponent("sentinel.txt")
        let sentinelData = Data("external sparse target".utf8)
        try sentinelData.write(to: sentinel, options: [.atomic])
        let run = makePhotoRecoveryPipeline(
            projectURL: fixture.projectURL,
            toolchain: fixture.toolchain,
            scripts: [
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["feature_extractor"],
                    result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                    onRun: { try self.writeFeatureDatabase(for: $0) }
                ),
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["matches_importer"],
                    result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                    onRun: { try self.writeFiftySevenPlusThreeOrderedFaissResults(for: $0) }
                ),
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["matches_importer"],
                    result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                    onRun: { try self.writeFiftySevenPlusThreeOrderedFaissResults(for: $0) }
                ),
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["mapper"],
                    result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                    stdoutLines: ["Retriangulation and Global bundle adjustment"],
                    onRun: { _ in
                        try FileManager.default.removeItem(at: fixture.paths.colmapSparseURL)
                        try FileManager.default.createSymbolicLink(
                            at: fixture.paths.colmapSparseURL,
                            withDestinationURL: unsafeSparseRoot
                        )
                    }
                ),
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["matches_importer"],
                    result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                    onRun: { arguments in
                        XCTAssertEqual(try self.pairListLines(for: arguments).count, 1_770)
                        try self.writeVerifiedPairResults(for: arguments)
                    }
                ),
            ] + successfulMappingScripts(
                colmapPath: fixture.toolchain.colmap.path,
                projectURL: fixture.projectURL,
                registeredViews: 60,
                totalViews: 60,
                pointCount: 20
            )
        )

        try await run.pipeline.run { _ in }

        XCTAssertEqual(run.runner.calls.count { $0.1.first == "mapper" }, 2)
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
        let evidence = try PairGraphEvidenceStore.load(
            from: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
        XCTAssertEqual(evidence.attempts.map(\.artifact.recoveryLevel), [
            .normal,
            .expanded,
            .maximum,
        ])
        XCTAssertEqual(evidence.attempts.last?.artifact.recoveryLevel, .maximum)
        XCTAssertEqual(evidence.attempts.last?.artifact.matcher, .faiss)
    }


    func testConnectedFaissMappingMissDoesNotRetryExactMatching() async throws {
        let temp = makeTempRoot()
        let fixture = try makePhotoRecoveryProject(
            in: temp,
            name: "ConnectedMappingExactFallback",
            photoCount: 8
        )
        let run = makePhotoRecoveryPipeline(
            projectURL: fixture.projectURL,
            toolchain: fixture.toolchain,
            scripts: [
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try self.writeFeatureDatabase(for: $0) }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try self.writeVerifiedPairResults(for: $0) }
            ),
            ] + successfulMappingScripts(
                colmapPath: fixture.toolchain.colmap.path,
                projectURL: fixture.projectURL,
                registeredViews: 4,
                totalViews: 8,
                pointCount: 20
            ) + successfulMappingScripts(
                colmapPath: fixture.toolchain.colmap.path,
                projectURL: fixture.projectURL,
                registeredViews: 4,
                totalViews: 8,
                pointCount: 20
            )
        )

        await XCTAssertThrowsErrorAsync({
            try await run.pipeline.run { _ in }
        }, errorHandler: { error in
            guard case .lowQualityReconstruction =
                    error as? PipelineRunner.PipelineError else {
                return XCTFail("Expected the mapping-quality failure, got \(error)")
            }
        })

        let evidence = try PairGraphEvidenceStore.load(
            from: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
        XCTAssertEqual(evidence.attempts.map(\.artifact.matcher), [.faiss])
        let matchingCalls = run.runner.calls.filter { $0.1.first == "matches_importer" }
        XCTAssertEqual(matchingCalls.count, 1)
        XCTAssertEqual(
            value(for: "--SiftMatching.cpu_brute_force_matcher", in: matchingCalls[0].1),
            "0"
        )
        XCTAssertFalse(run.runner.calls.contains { $0.1.first == "local_vocab_retriever" })
        let mapperCalls = run.runner.calls.filter { $0.1.first == "mapper" }
        XCTAssertEqual(mapperCalls.count, 2)
        XCTAssertEqual(
            mapperCalls.compactMap {
                value(for: "--Mapper.ba_global_frames_ratio", in: $0.1)
            },
            ["1.4", "1.1"]
        )
    }


    func testMismatchedRecoveryStateRestartsFaissFromPreservedFeatures() async throws {
        let temp = makeTempRoot()
        let fixture = try makePhotoRecoveryProject(
            in: temp,
            name: "MismatchedRecoveryRestart",
            photoCount: 8
        )
        let featureRun = makePhotoRecoveryPipeline(
            projectURL: fixture.projectURL,
            toolchain: fixture.toolchain,
            scripts: [
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["feature_extractor"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { try self.writeFeatureDatabase(for: $0) }
                ),
            ],
            stopAfterStage: .sfmFeatures
        )
        try await featureRun.pipeline.run { _ in }

        let imageNames = selectedImageNames(in: fixture.paths)
        let sourcePlan = try ColmapPairPlan.exhaustive(imageNames: imageNames)
        let pairListURL = fixture.paths.colmapSeedURL.appendingPathComponent(
            "stale-evidence-pairs.txt"
        )
        try sourcePlan.serializedData.write(to: pairListURL, options: [.atomic])
        try writeVerifiedPairResults(for: [
            "--database_path", fixture.paths.colmapDatabaseURL.path,
            "--match_list_path", pairListURL.path,
        ])
        _ = try persistPairGraphEvidenceFixture(
            paths: fixture.paths,
            imageNames: imageNames
        )
        let featureDigest = try ColmapDatabaseDigester
            .digests(at: fixture.paths.colmapDatabaseURL).feature
        try PairGraphRecoveryStore.save(
            PairGraphRecoveryState(
                selectedFramesDigest: String(repeating: "0", count: 64),
                imageNames: imageNames,
                mode: .policy,
                activeRecoveryLevel: .normal,
                activePlan: sourcePlan,
                attempts: [
                    PairGraphAttemptEvidence(
                        artifact: PairMatchingAttemptArtifact(
                            attemptNumber: 1,
                            matcher: .faiss,
                            recoveryLevel: .normal,
                            outcome: .failed,
                            scheduledPairCount: sourcePlan.pairs.count,
                            attemptedPairCount: 0,
                            rawMatchedPairCount: 0,
                            spatiallyVerifiedPairCount: 0,
                            durationSeconds: 1
                        ),
                        scheduledPairs: sourcePlan.pairs
                    ),
                ],
                matchingDurationSeconds: 1,
                fallbackReasons: []
            ),
            to: fixture.paths.pairGraphRecoveryURL,
            projectPaths: fixture.paths
        )
        try ColmapDatabaseMatchStore.clearMatchingResults(
            at: fixture.paths.colmapDatabaseURL
        )
        try writePartialMatchRows(at: fixture.paths.colmapDatabaseURL)
        XCTAssertEqual(
            try matchingRowCounts(databasePath: fixture.paths.colmapDatabaseURL.path),
            [1, 1]
        )
        let previousOutput = Data("previous validated splat".utf8)
        try FileManager.default.createDirectory(
            at: fixture.paths.outputURL,
            withIntermediateDirectories: true
        )
        try previousOutput.write(
            to: fixture.paths.outputURL.appendingPathComponent("splat.ply"),
            options: [.atomic]
        )

        let resumed = makePhotoRecoveryPipeline(
            projectURL: fixture.projectURL,
            toolchain: fixture.toolchain,
            scripts: [
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["matches_importer"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { arguments in
                        XCTAssertEqual(
                            self.value(
                                for: "--SiftMatching.cpu_brute_force_matcher",
                                in: arguments
                            ),
                            "0"
                        )
                        XCTAssertEqual(
                            try self.matchingRowCounts(
                                databasePath: fixture.paths.colmapDatabaseURL.path
                            ),
                            [0, 0]
                        )
                        try self.writeVerifiedPairResults(for: arguments)
                    }
                ),
            ] + successfulMappingScripts(
                colmapPath: fixture.toolchain.colmap.path,
                projectURL: fixture.projectURL,
                registeredViews: 8,
                totalViews: 8,
                pointCount: 20
            )
        )
        let events = PipelineEventSink()

        try await resumed.pipeline.run(resumeFrom: .sfmFeatures) { events.append($0) }

        XCTAssertNotNil(events.stageLog(
            containing: "Discarded inconsistent pair-graph recovery state"
        ))
        XCTAssertFalse(resumed.runner.calls.contains { call in
            ["feature_extractor", "local_vocab_retriever"].contains(call.1.first)
        })
        XCTAssertEqual(
            try ColmapDatabaseDigester.digests(
                at: fixture.paths.colmapDatabaseURL
            ).feature,
            featureDigest
        )
        let accepted = try PairGraphEvidenceStore.load(
            from: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
        XCTAssertEqual(accepted.attempts.map(\.artifact.matcher), [.faiss])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.pairGraphRecoveryURL.path
        ))
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.outputURL.appendingPathComponent("splat.ply")),
            previousOutput
        )
    }

    func testRealMatcherCancellationRollsBackTerminationReceiptBeforeResume() async throws {
        let temp = makeTempRoot()
        let fixture = try makePhotoRecoveryProject(
            in: temp,
            name: "RealMatcherCancellationReceipt",
            photoCount: 8
        )
        let launchedMarker = temp.appendingPathComponent("matcher-launched")
        let executable = """
        #!/bin/bash
        if [[ "$1" == "matches_importer" ]]; then
          /usr/bin/touch "\(launchedMarker.path)"
          /bin/sleep 30
        fi
        exit 0

        """
        try executable.write(
            to: fixture.toolchain.colmap,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fixture.toolchain.colmap.path
        )
        let executableDigest = try GeometryArtifactStore.sha256(
            of: fixture.toolchain.colmap
        )
        try """
        {
          "toolchain_name": "colmap",
          "source_version": "4.1.1",
          "source_commit": "a0d785fba74b2664f31edc4a29026a8b27c00f67",
          "executable_sha256": "\(executableDigest)"
        }
        """.write(
            to: fixture.toolchain.root.appendingPathComponent(
                "provenance/colmap.json"
            ),
            atomically: true,
            encoding: .utf8
        )

        let featureRun = makePhotoRecoveryPipeline(
            projectURL: fixture.projectURL,
            toolchain: fixture.toolchain,
            scripts: [
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["feature_extractor"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { try self.writeFeatureDatabase(for: $0) }
                ),
            ],
            stopAfterStage: .sfmFeatures
        )
        try await featureRun.pipeline.run { _ in }

        let interruptedPipeline = PipelineRunner(
            projectURL: fixture.projectURL,
            config: makePipelineConfig(
                toolchain: fixture.toolchain,
                candidateRoute: .colmap,
                skipTraining: true
            ),
            tooling: .init(runner: SubprocessRunner())
        )
        let task = Task {
            try await interruptedPipeline.run(resumeFrom: .sfmMatching) { _ in }
        }
        for _ in 0..<500 where !FileManager.default.fileExists(
            atPath: launchedMarker.path
        ) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: launchedMarker.path))
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected real matcher cancellation")
        } catch is CancellationError {
            // The real runner persists its termination callback before rethrowing.
        }

        let interruptedLedger = try GeometryWorkerExecutionArtifactStore.load(
            from: fixture.paths.workerExecutionURL,
            projectPaths: fixture.paths
        )
        XCTAssertTrue(interruptedLedger.matchingInvocations.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.pairGraphRecoveryURL.path
        ))

        let resumed = makePhotoRecoveryPipeline(
            projectURL: fixture.projectURL,
            toolchain: fixture.toolchain,
            scripts: [
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["matches_importer"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { try self.writeVerifiedPairResults(for: $0) }
                ),
            ] + successfulMappingScripts(
                colmapPath: fixture.toolchain.colmap.path,
                projectURL: fixture.projectURL,
                registeredViews: 8,
                totalViews: 8,
                pointCount: 20
            )
        )
        try await resumed.pipeline.run(resumeFrom: .sfmMatching) { _ in }

        let accepted = try PairGraphEvidenceStore.load(
            from: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
        XCTAssertEqual(accepted.attempts.map(\.artifact.attemptNumber), [1])
        let finalLedger = try GeometryWorkerExecutionArtifactStore.load(
            from: fixture.paths.workerExecutionURL,
            projectPaths: fixture.paths
        )
        XCTAssertEqual(finalLedger.matchingInvocations.count, 1)
        XCTAssertEqual(
            finalLedger.matchingInvocations.first?.pairExecution?.attemptOrdinal,
            1
        )
    }

    func testInterruptedSameScheduleExactMatchingResumesWithoutRepeatingFeaturesOrFaiss() async throws {
        let temp = makeTempRoot()
        let fixture = try makePhotoRecoveryProject(
            in: temp,
            name: "InterruptedSameScheduleExactRecovery",
            photoCount: 8
        )
        let firstRun = makePhotoRecoveryPipeline(
            projectURL: fixture.projectURL,
            toolchain: fixture.toolchain,
            scripts: [
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["feature_extractor"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { try self.writeFeatureDatabase(for: $0) }
                ),
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["matches_importer"],
                    result: .init(
                        exitCode: SIGSEGV,
                        terminationReason: .uncaughtSignal,
                        stdout: "",
                        stderr: "segmentation fault"
                    ),
                    onRun: { arguments in
                        XCTAssertEqual(
                            self.value(
                                for: "--SiftMatching.cpu_brute_force_matcher",
                                in: arguments
                            ),
                            "0"
                        )
                    }
                ),
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["matches_importer"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { arguments in
                        XCTAssertEqual(
                            self.value(
                                for: "--SiftMatching.cpu_brute_force_matcher",
                                in: arguments
                            ),
                            "1"
                        )
                        XCTAssertEqual(try self.pairListLines(for: arguments).count, 28)
                        let databasePath = try XCTUnwrap(
                            self.value(for: "--database_path", in: arguments)
                        )
                        try self.writePartialMatchRows(
                            at: URL(fileURLWithPath: databasePath)
                        )
                        throw CancellationError()
                    }
                ),
            ]
        )
        do {
            try await firstRun.pipeline.run { _ in }
            XCTFail("Expected same-schedule exact matching to be interrupted")
        } catch is CancellationError {
            // Expected.
        }

        let imageNames = selectedImageNames(in: fixture.paths)
        let pendingRecovery = try PairGraphRecoveryStore.loadBound(
            from: fixture.paths.pairGraphRecoveryURL,
            expectedImageNames: imageNames,
            projectPaths: fixture.paths
        ).restoredRecovery()
        XCTAssertEqual(pendingRecovery.mode, .sameScheduleExact)
        XCTAssertEqual(pendingRecovery.activePlan.pairs.count, 28)
        XCTAssertEqual(pendingRecovery.attempts.map(\.artifact.matcher), [.faiss])
        XCTAssertEqual(pendingRecovery.attempts.map(\.artifact.outcome), [.failed])
        XCTAssertEqual(
            try matchingRowCounts(databasePath: fixture.paths.colmapDatabaseURL.path),
            [1, 1]
        )
        let featureDigest = try ColmapDatabaseDigester
            .digests(at: fixture.paths.colmapDatabaseURL).feature
        let previousOutput = Data("previous validated splat".utf8)
        try FileManager.default.createDirectory(
            at: fixture.paths.outputURL,
            withIntermediateDirectories: true
        )
        try previousOutput.write(
            to: fixture.paths.outputURL.appendingPathComponent("splat.ply"),
            options: [.atomic]
        )

        let resumed = makePhotoRecoveryPipeline(
            projectURL: fixture.projectURL,
            toolchain: fixture.toolchain,
            scripts: [
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["matches_importer"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { arguments in
                        XCTAssertEqual(
                            self.value(
                                for: "--SiftMatching.cpu_brute_force_matcher",
                                in: arguments
                            ),
                            "1"
                        )
                        XCTAssertEqual(try self.pairListLines(for: arguments).count, 28)
                        XCTAssertEqual(
                            try self.matchingRowCounts(
                                databasePath: fixture.paths.colmapDatabaseURL.path
                            ),
                            [0, 0]
                        )
                        try self.writeVerifiedPairResults(for: arguments)
                    }
                ),
            ] + successfulMappingScripts(
                colmapPath: fixture.toolchain.colmap.path,
                projectURL: fixture.projectURL,
                registeredViews: 8,
                totalViews: 8,
                pointCount: 20
            )
        )

        try await resumed.pipeline.run(resumeFrom: .sfmMatching) { _ in }

        XCTAssertEqual(resumed.runner.calls.first?.1.first, "matches_importer")
        XCTAssertEqual(
            resumed.runner.calls.count { $0.1.first == "matches_importer" },
            1
        )
        XCTAssertFalse(resumed.runner.calls.contains { call in
            ["feature_extractor", "local_vocab_retriever"].contains(call.1.first)
        })
        XCTAssertEqual(
            try ColmapDatabaseDigester.digests(
                at: fixture.paths.colmapDatabaseURL
            ).feature,
            featureDigest
        )
        let accepted = try PairGraphEvidenceStore.load(
            from: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
        XCTAssertEqual(accepted.attempts.map(\.artifact.matcher), [.faiss, .exact])
        XCTAssertEqual(
            accepted.attempts[0].scheduledPairs,
            accepted.attempts[1].scheduledPairs
        )
        XCTAssertEqual(accepted.pairListDigest, pendingRecovery.activePlan.sha256)
        let finished = try ProjectMetadataStore.load(from: fixture.paths.metadataURL)
        let workerExecution = try GeometryArtifactStore.load(
            from: fixture.paths.geometryManifestURL,
            projectPaths: fixture.paths,
            expectedInput: finished.input
        ).workerExecution
        XCTAssertEqual(
            workerExecution.matchingInvocations.map(\.command),
            [.matchesImporter, .matchesImporter]
        )
        XCTAssertEqual(
            workerExecution.matchingInvocations.map(\.succeeded),
            [false, true],
            "Resume must append to the failed matching attempt instead of erasing it."
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.pairGraphRecoveryURL.path
        ))
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.outputURL.appendingPathComponent("splat.ply")),
            previousOutput
        )
    }

    func testCompletedFaissEvidenceSupersedesStalePendingExactIntent() async throws {
        let temp = makeTempRoot()
        let fixture = try makePhotoRecoveryProject(
            in: temp,
            name: "CompletedFaissSupersedesExact",
            photoCount: 8
        )
        let firstRun = makePhotoRecoveryPipeline(
            projectURL: fixture.projectURL,
            toolchain: fixture.toolchain,
            scripts: [
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["feature_extractor"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { try self.writeFeatureDatabase(for: $0) }
                ),
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["matches_importer"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { try self.writeVerifiedPairResults(for: $0) }
                ),
            ],
            stopAfterStage: .sfmMatching
        )
        try await firstRun.pipeline.run { _ in }

        let evidence = try PairGraphEvidenceStore.loadVerified(
            from: fixture.paths.pairGraphEvidenceURL,
            expectedImageNames: selectedImageNames(in: fixture.paths),
            databaseURL: fixture.paths.colmapDatabaseURL,
            projectPaths: fixture.paths
        )
        var staleAttempt = try XCTUnwrap(evidence.attempts.last)
        staleAttempt.artifact.outcome = .failed
        let activePlan = try evidence.restoredPairPlan()
        try PairGraphRecoveryStore.save(
            PairGraphRecoveryState(
                selectedFramesDigest: evidence.selectedFramesDigest,
                imageNames: evidence.imageNames,
                groups: [ColmapPairGroup(
                    imageNames: evidence.imageNames,
                    isVideo: false
                )],
                pairingPolicy: evidence.pairingPolicy,
                planBinding: evidence.planBinding,
                mode: .sameScheduleExact,
                exactRecoveryReason: .faissCrash,
                activeRecoveryLevel: staleAttempt.artifact.recoveryLevel,
                activePlan: activePlan,
                activeRetrieval: staleAttempt.retrieval,
                attempts: [staleAttempt],
                retrievalWasScheduled: evidence.retrievalWasScheduled,
                usedLocalVocabularyRetrieval:
                    evidence.usedLocalVocabularyRetrieval,
                matchingDurationSeconds: staleAttempt.artifact.durationSeconds,
                fallbackReasons: evidence.fallbackReasons
            ),
            to: fixture.paths.pairGraphRecoveryURL,
            projectPaths: fixture.paths
        )

        let resumed = makePhotoRecoveryPipeline(
            projectURL: fixture.projectURL,
            toolchain: fixture.toolchain,
            scripts: successfulMappingScripts(
                colmapPath: fixture.toolchain.colmap.path,
                projectURL: fixture.projectURL,
                registeredViews: 8,
                totalViews: 8,
                pointCount: 20
            )
        )
        try await resumed.pipeline.run(resumeFrom: .sfmMatching) { _ in }

        XCTAssertFalse(resumed.runner.calls.contains {
            $0.1.first == "matches_importer"
        })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.pairGraphRecoveryURL.path
        ))
    }

    func testFailedExactAttemptIsTerminalAcrossRelaunch() async throws {
        let temp = makeTempRoot()
        let fixture = try makePhotoRecoveryProject(
            in: temp,
            name: "FailedExactIsTerminal",
            photoCount: 8
        )
        let firstRun = makePhotoRecoveryPipeline(
            projectURL: fixture.projectURL,
            toolchain: fixture.toolchain,
            scripts: [
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["feature_extractor"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { try self.writeFeatureDatabase(for: $0) }
                ),
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["matches_importer"],
                    result: .init(
                        exitCode: SIGSEGV,
                        terminationReason: .uncaughtSignal,
                        stdout: "",
                        stderr: "segmentation fault"
                    )
                ),
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["matches_importer"],
                    result: .init(
                        exitCode: 1,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: "exact matcher failed"
                    )
                ),
            ]
        )
        await XCTAssertThrowsErrorAsync({
            try await firstRun.pipeline.run { _ in }
        })
        let terminal = try PairGraphRecoveryStore.loadBound(
            from: fixture.paths.pairGraphRecoveryURL,
            expectedImageNames: selectedImageNames(in: fixture.paths),
            projectPaths: fixture.paths
        ).restoredRecovery()
        XCTAssertEqual(terminal.mode, .terminalExact)
        XCTAssertEqual(
            terminal.attempts.map(\.artifact.matcher),
            [.faiss, .exact]
        )
        let selectedNames = selectedImageNames(in: fixture.paths)
        let selectedManifest = try JSONDecoder().decode(
            [PipelineRunner.SelectedFrameMapping].self,
            from: Data(contentsOf: fixture.paths.framesSelectedManifestURL)
        )
        XCTAssertEqual(
            terminal.groups,
            try PipelineRunner.colmapPairGroups(
                imageNames: selectedNames,
                manifest: selectedManifest
            )
        )
        let persistedMetadata = try ProjectMetadataStore.load(
            from: fixture.paths.metadataURL
        )
        XCTAssertEqual(
            terminal.planBinding,
            PairGraphPlanBinding(try XCTUnwrap(persistedMetadata.resolvedRunPlan))
        )

        let resumed = makePhotoRecoveryPipeline(
            projectURL: fixture.projectURL,
            toolchain: fixture.toolchain,
            scripts: [
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["matches_importer"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    )
                ),
            ]
        )
        await XCTAssertThrowsErrorAsync({
            try await resumed.pipeline.run(resumeFrom: .sfmMatching) { _ in }
        }, errorHandler: { error in
            guard let recoveryError = error as? PairGraphRecoveryStoreError else {
                return XCTFail("Unexpected recovery error: \(error)")
            }
            XCTAssertEqual(
                recoveryError,
                .terminalExactRecovery
            )
        })
        XCTAssertFalse(resumed.runner.calls.contains {
            $0.1.first == "matches_importer"
        })
        let preservedTerminal = try PairGraphRecoveryStore.loadBound(
            from: fixture.paths.pairGraphRecoveryURL,
            expectedImageNames: selectedNames,
            expectedGroups: terminal.groups,
            projectPaths: fixture.paths
        ).restoredRecovery()
        XCTAssertEqual(preservedTerminal, terminal)
    }

    func testInterruptedPolicyRecoveryResumesThePersistedPairSchedule() async throws {
        let temp = makeTempRoot()
        let fixture = try makePhotoRecoveryProject(
            in: temp,
            name: "InterruptedPolicyRecovery",
            photoCount: 61
        )
        let imageNames = (0..<61).map { String(format: "frame_%06d.jpg", $0) }
        let chain = (0..<60).map { "\(imageNames[$0]) \(imageNames[$0 + 1])" }
        let expanded = chain + ["\(imageNames[0]) \(imageNames[60])"]
        let firstRun = makePhotoRecoveryPipeline(
            projectURL: fixture.projectURL,
            toolchain: fixture.toolchain,
            scripts: [
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["feature_extractor"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { try self.writeFeatureDatabase(for: $0) }
                ),
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["local_vocab_retriever"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { try self.writeVocabularyOutput(for: $0, pairLines: chain) }
                ),
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["matches_importer"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: {
                        try self.writeVerifiedPairResults(for: $0, verifiedRows: 0)
                    }
                ),
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["local_vocab_retriever"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { try self.writeVocabularyOutput(for: $0, pairLines: expanded) }
                ),
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["matches_importer"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { _ in throw CancellationError() }
                ),
            ]
        )

        do {
            try await firstRun.pipeline.run { _ in }
            XCTFail("Expected expanded policy matching to be interrupted")
        } catch is CancellationError {
            // Expected.
        }

        let pending = try PairGraphRecoveryStore.loadBound(
            from: fixture.paths.pairGraphRecoveryURL,
            expectedImageNames: selectedImageNames(in: fixture.paths),
            projectPaths: fixture.paths
        ).restoredRecovery()
        XCTAssertEqual(pending.mode, .policy)
        XCTAssertEqual(pending.phase, .matching)
        XCTAssertEqual(pending.recoveryLevel, .expanded)
        XCTAssertEqual(pending.attempts.map(\.artifact.outcome), [.rejected])
        XCTAssertEqual(pending.activePlan.pairs.count, 61)

        let resumed = makePhotoRecoveryPipeline(
            projectURL: fixture.projectURL,
            toolchain: fixture.toolchain,
            scripts: [
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["matches_importer"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { arguments in
                        XCTAssertEqual(
                            try self.pairListLines(for: arguments),
                            pending.activePlan.pairLines
                        )
                        try self.writeVerifiedPairResults(for: arguments)
                    }
                ),
            ] + successfulMappingScripts(
                colmapPath: fixture.toolchain.colmap.path,
                projectURL: fixture.projectURL,
                registeredViews: 61,
                totalViews: 61,
                pointCount: 20
            )
        )

        try await resumed.pipeline.run(resumeFrom: .sfmMatching) { _ in }

        XCTAssertFalse(resumed.runner.calls.contains {
            $0.1.first == "local_vocab_retriever"
        })
        let accepted = try PairGraphEvidenceStore.load(
            from: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
        XCTAssertEqual(accepted.attempts.map(\.artifact.outcome), [
            .rejected,
            .completed,
        ])
        XCTAssertEqual(accepted.pairListDigest, pending.activePlan.sha256)
    }

    func testInterruptedClassicalMatchingClearsPartialExactRowsBeforeFaissResume() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent(
            "InterruptedClassicalMatching.easysplatproj",
            isDirectory: true
        )
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<8 {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(index)
            )
        }

        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(
            ProjectMetadata(
                title: "Interrupted classical matching",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    detailProfile: .fast,
                    inputOrdering: .unordered,
                    photoSelection: .useAllValidPhotos
                )
            ),
            paths: paths
        )
        let toolchain = try makeToolchain(root: temp)
        let featureRunner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try self.writeFeatureDatabase(for: $0) }
            )
        ])
        let featurePipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                skipTraining: true,
                stopAfterStage: .sfmFeatures
            ),
            tooling: .init(runner: featureRunner)
        )
        try await featurePipeline.run { _ in }
        let partialPairs = temp.appendingPathComponent("partial-pairs.txt")
        try "frame_000000.jpg frame_000001.jpg\n".write(
            to: partialPairs,
            atomically: true,
            encoding: .utf8
        )
        try writeVerifiedPairResults(for: [
            "--database_path", paths.colmapDatabaseURL.path,
            "--match_list_path", partialPairs.path,
        ])
        try markMatchingAsInterrupted(paths: paths)
        XCTAssertEqual(try databaseRowCount("matches", at: paths.colmapDatabaseURL), 1)
        XCTAssertEqual(
            try databaseRowCount("two_view_geometries", at: paths.colmapDatabaseURL),
            1
        )

        let resumeRunner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(
                        self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: args),
                        "0"
                    )
                    XCTAssertEqual(
                        try? self.databaseRowCount("matches", at: paths.colmapDatabaseURL),
                        0
                    )
                    XCTAssertEqual(
                        try? self.databaseRowCount(
                            "two_view_geometries",
                            at: paths.colmapDatabaseURL
                        ),
                        0
                    )
                    try? self.writeVerifiedPairResults(for: args)
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                stdoutLines: ["Retriangulation and Global bundle adjustment"],
                onRun: { _ in try? self.writeSparseModel(at: projectURL) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: 8 / 8\nPoints: 20\nObservations: 160\nMean track length: 8.0\nMean reprojection error: 0.5\n",
                    stderr: ""
                ),
                onRun: nil
            ),
        ])
        let events = PipelineEventSink()
        let resumedPipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                skipTraining: true
            ),
            tooling: .init(runner: resumeRunner)
        )

        try await resumedPipeline.run(resumeFrom: .sfmFeatures) { events.append($0) }

        XCTAssertNotNil(events.stageLog(containing: "Discarded partial image matches"))
        XCTAssertFalse(resumeRunner.calls.contains { $0.1.first == "feature_extractor" })
    }

    func testBundleAdjustmentPolicyChangePreservesMatchesAndRerunsOnlyMapping() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent(
            "BundleAdjustmentPolicyChange.easysplatproj",
            isDirectory: true
        )
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<8 {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(index)
            )
        }

        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(
            ProjectMetadata(
                title: "Bundle adjustment policy change",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    detailProfile: .fast,
                    inputOrdering: .unordered,
                    photoSelection: .useAllValidPhotos
                )
            ),
            paths: paths
        )
        let toolchain = try makeToolchain(root: temp)
        let firstRunner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try? self.writeFeatureDatabase(for: $0) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try? self.writeVerifiedPairResults(for: $0) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                stdoutLines: ["Retriangulation and Global bundle adjustment"],
                onRun: { _ in try? self.writeSparseModel(at: projectURL) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: 8 / 8\nPoints: 20\nObservations: 160\nMean track length: 8.0\nMean reprojection error: 0.5\n",
                    stderr: ""
                )
            ),
        ])
        let firstPipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                skipTraining: true
            ),
            tooling: .init(runner: firstRunner)
        )
        try await firstPipeline.run { _ in }

        var staleMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        staleMetadata.resolvedRunPlan?.baGlobalFramesRatio = 1.2
        try ProjectMetadataStore.save(staleMetadata, to: paths.metadataURL)
        XCTAssertEqual(try databaseRowCount("matches", at: paths.colmapDatabaseURL), 28)
        let pairEvidenceBefore = try Data(contentsOf: paths.pairGraphEvidenceURL)

        let resumeRunner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                stdoutLines: ["Retriangulation and Global bundle adjustment"],
                onRun: { _ in try? self.writeSparseModel(at: projectURL) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: 8 / 8\nPoints: 20\nObservations: 160\nMean track length: 8.0\nMean reprojection error: 0.5\n",
                    stderr: ""
                )
            ),
        ])
        let events = PipelineEventSink()
        let resumedPipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                skipTraining: true
            ),
            tooling: .init(runner: resumeRunner)
        )
        try await resumedPipeline.run(resumeFrom: .sfmMapping) { events.append($0) }

        XCTAssertFalse(resumeRunner.calls.contains { $0.1.first == "feature_extractor" })
        XCTAssertFalse(resumeRunner.calls.contains { $0.1.first == "matches_importer" })
        XCTAssertEqual(resumeRunner.calls.filter { $0.1.first == "mapper" }.count, 1)
        XCTAssertNil(events.stageLog(containing: "Discarded stale image matches"))
        XCTAssertEqual(try databaseRowCount("matches", at: paths.colmapDatabaseURL), 28)
        XCTAssertEqual(
            try databaseRowCount("two_view_geometries", at: paths.colmapDatabaseURL),
            28
        )
        XCTAssertEqual(try Data(contentsOf: paths.pairGraphEvidenceURL), pairEvidenceBefore)
    }

    func testPhotoOnlyInjectedPlanIgnoresUnusedVideoSourceAnalysisWorkerDifference() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent(
            "PhotoOnlyInjectedPlan.easysplatproj",
            isDirectory: true
        )
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<8 {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(index)
            )
        }

        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(
            ProjectMetadata(
                title: "Photo-only injected plan",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    detailProfile: .fast,
                    inputOrdering: .unordered,
                    photoSelection: .useAllValidPhotos
                )
            ),
            paths: paths
        )
        let toolchain = try makeToolchain(root: temp)
        let firstRunner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try? self.writeFeatureDatabase(for: $0) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try? self.writeVerifiedPairResults(for: $0) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                stdoutLines: ["Retriangulation and Global bundle adjustment"],
                onRun: { _ in try? self.writeSparseModel(at: projectURL) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: 8 / 8\nPoints: 20\nObservations: 160\nMean track length: 8.0\nMean reprojection error: 0.5\n",
                    stderr: ""
                )
            ),
        ])
        let firstPipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                skipTraining: true
            ),
            tooling: .init(runner: firstRunner)
        )
        try await firstPipeline.run { _ in }

        let completedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let acceptedPlan = try XCTUnwrap(completedMetadata.resolvedRunPlan)
        let acceptedGeometry = try GeometryArtifactStore.load(
            from: paths.geometryManifestURL,
            projectPaths: paths,
            expectedInput: completedMetadata.input
        )
        XCTAssertEqual(acceptedPlan.geometryWorkerBudget.maximumConcurrentVideoSourceAnalysisTasks, 1)
        let manifestBeforeResume = try Data(contentsOf: paths.geometryManifestURL)
        let workerEvidenceBeforeResume = try Data(contentsOf: paths.workerExecutionURL)

        var injectedPlan = acceptedPlan
        injectedPlan.geometryWorkerBudget.maximumConcurrentVideoSourceAnalysisTasks += 1
        let resumeRunner = MockSubprocessRunner(scripts: [])
        let resumedPipeline = PipelineRunner(
            projectURL: projectURL,
            config: PipelineRunner.PipelineConfig(
                toolchain: toolchain,
                developmentOverrides: DevelopmentOverrides(
                    candidateRoute: .colmap,
                    skipTraining: true
                ),
                hardwareProfile: HardwareProfile(
                    memoryGB: 48,
                    cpuCount: 16,
                    gpuWorkingSetGB: 36
                ),
                resolvedRunPlan: injectedPlan
            ),
            tooling: .init(runner: resumeRunner)
        )
        try await resumedPipeline.run(resumeFrom: .sfmMapping) { _ in }

        XCTAssertTrue(
            resumeRunner.calls.isEmpty,
            "An unused photo-only video-analysis limit must not invalidate completed geometry."
        )
        XCTAssertEqual(try Data(contentsOf: paths.geometryManifestURL), manifestBeforeResume)
        XCTAssertEqual(try Data(contentsOf: paths.workerExecutionURL), workerEvidenceBeforeResume)
        let resumedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(resumedMetadata.resolvedRunPlan, acceptedPlan)
        XCTAssertEqual(
            try GeometryArtifactStore.load(
                from: paths.geometryManifestURL,
                projectPaths: paths,
                expectedInput: resumedMetadata.input
            ),
            acceptedGeometry
        )
        XCTAssertEqual(resumedMetadata.state.stage, .sfmMapping)
    }

    func testPlanChangeRecoversWhenWorkerEvidenceWasRebasedBeforeMetadata() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent(
            "EvidenceFirstPlanChange.easysplatproj",
            isDirectory: true
        )
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<8 {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(index)
            )
        }

        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(
            ProjectMetadata(
                title: "Evidence-first plan change",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    detailProfile: .fast,
                    inputOrdering: .unordered,
                    photoSelection: .useAllValidPhotos
                )
            ),
            paths: paths
        )
        let toolchain = try makeToolchain(root: temp)
        let firstRunner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try? self.writeFeatureDatabase(for: $0) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try? self.writeVerifiedPairResults(for: $0) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                stdoutLines: ["Retriangulation and Global bundle adjustment"],
                onRun: { _ in try? self.writeSparseModel(at: projectURL) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: 8 / 8\nPoints: 20\nObservations: 160\nMean track length: 8.0\nMean reprojection error: 0.5\n",
                    stderr: ""
                )
            ),
        ])
        try await PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                skipTraining: true
            ),
            tooling: .init(runner: firstRunner)
        ).run { _ in }

        let oldMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let oldPlan = try XCTUnwrap(oldMetadata.resolvedRunPlan)
        var changedPlan = oldPlan
        changedPlan.geometryWorkerBudget.coupledMatchingWorkers -= 1
        XCTAssertEqual(
            RunPlanResolver.safeResumeStage(
                .sfmMapping,
                input: oldMetadata.input,
                previousPlan: oldPlan,
                currentPlan: changedPlan
            ),
            .sfmFeatures
        )

        var rebasedEvidence = try GeometryWorkerExecutionArtifactStore.load(
            from: paths.workerExecutionURL,
            expectedBudget: oldPlan.geometryWorkerBudget,
            projectPaths: paths
        )
        rebasedEvidence.resolvedBudget = changedPlan.geometryWorkerBudget
        rebasedEvidence.matchingInvocations = []
        rebasedEvidence.vocabularyRetrievalInvocations = []
        rebasedEvidence.mappingAndRefinementInvocations = []
        _ = try GeometryWorkerExecutionArtifactStore.save(
            rebasedEvidence,
            to: paths.workerExecutionURL,
            expectedBudget: changedPlan.geometryWorkerBudget,
            projectPaths: paths
        )
        XCTAssertEqual(
            try ProjectMetadataStore.load(from: paths.metadataURL).resolvedRunPlan,
            oldPlan,
            "The fixture represents a stop after evidence rebase but before metadata commit."
        )

        let resumeRunner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try? self.writeVerifiedPairResults(for: $0) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                stdoutLines: ["Retriangulation and Global bundle adjustment"],
                onRun: { _ in try? self.writeSparseModel(at: projectURL) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: 8 / 8\nPoints: 20\nObservations: 160\nMean track length: 8.0\nMean reprojection error: 0.5\n",
                    stderr: ""
                )
            ),
        ])
        try await PipelineRunner(
            projectURL: projectURL,
            config: PipelineRunner.PipelineConfig(
                toolchain: toolchain,
                developmentOverrides: DevelopmentOverrides(
                    candidateRoute: .colmap,
                    skipTraining: true
                ),
                hardwareProfile: HardwareProfile(
                    memoryGB: 48,
                    cpuCount: 16,
                    gpuWorkingSetGB: 36
                ),
                resolvedRunPlan: changedPlan
            ),
            tooling: .init(runner: resumeRunner)
        ).run(resumeFrom: .sfmMapping) { _ in }

        XCTAssertEqual(
            resumeRunner.calls.compactMap { $0.1.first },
            ["matches_importer", "mapper", "model_analyzer"]
        )
        let resumedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(resumedMetadata.resolvedRunPlan, changedPlan)
        let resumedGeometry = try GeometryArtifactStore.load(
            from: paths.geometryManifestURL,
            projectPaths: paths,
            expectedInput: resumedMetadata.input
        )
        XCTAssertEqual(resumedGeometry.workerExecution.resolvedBudget, changedPlan.geometryWorkerBudget)
        XCTAssertEqual(
            try GeometryWorkerExecutionArtifactStore.load(
                from: paths.workerExecutionURL,
                expectedBudget: changedPlan.geometryWorkerBudget,
                projectPaths: paths
            ),
            resumedGeometry.workerExecution
        )
    }

    func testFaissCrashOnOversizedDenserRetryDoesNotUseExactMatching() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("FaissRetryRecovery.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<30 {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(index)
            )
        }

        let metadata = ProjectMetadata(
            title: "FAISS retry recovery",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .walkthrough,
                detailProfile: .fast,
                inputOrdering: .continuous,
                photoSelection: .useAllValidPhotos
            )
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(metadata, paths: paths)
        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try? self.writeFeatureDatabase(for: $0) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["local_vocab_retriever"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try self.writeVocabularyOutput(for: $0) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: args), "0")
                    try self.writeVerifiedPairResults(for: args, verifiedRows: 0)
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["local_vocab_retriever"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try self.writeVocabularyOutput(for: $0) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(
                    exitCode: SIGSEGV,
                    terminationReason: .uncaughtSignal,
                    stdout: "",
                    stderr: "segmentation fault"
                ),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: args), "0")
                }
            ),
        ])
        let events = PipelineEventSink()
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                skipTraining: true
            ),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync({
            try await pipeline.run { events.append($0) }
        }, errorHandler: { error in
            guard case let ColmapRunnerError.failed(command, _, _, _, _) = error else {
                return XCTFail("Expected the original typed matcher failure, got \(error)")
            }
            XCTAssertEqual(command, "matches_importer")
        })

        let commands = runner.calls.compactMap { $0.1.first }
        XCTAssertEqual(commands.filter { $0 == "feature_extractor" }.count, 1)
        XCTAssertEqual(commands.filter { $0 == "local_vocab_retriever" }.count, 2)
        XCTAssertEqual(commands.filter { $0 == "matches_importer" }.count, 2)
        XCTAssertNil(events.stageLog(containing: "preserving features and retrying with exact matching"))
        let recovery = try PairGraphRecoveryStore.loadBound(
            from: paths.pairGraphRecoveryURL,
            expectedImageNames: selectedImageNames(in: paths),
            projectPaths: paths
        )
        XCTAssertEqual(recovery.attempts.count, 2)
        XCTAssertEqual(recovery.attempts.map(\.artifact.recoveryLevel), [.normal, .expanded])
        XCTAssertEqual(recovery.attempts.map(\.artifact.matcher), [.faiss, .faiss])
        XCTAssertEqual(recovery.attempts.map(\.artifact.outcome), [.rejected, .failed])
        XCTAssertEqual(recovery.attempts.map(\.artifact.scheduledPairCount), [159, 282])
        let expandedAttempt = try XCTUnwrap(
            recovery.attempts.first { $0.artifact.recoveryLevel == .expanded }
        )
        XCTAssertGreaterThan(
            expandedAttempt.artifact.scheduledPairCount,
            DescriptorMatcherRecoveryPolicy.maximumExactRecoveryPairCount
        )
    }

    func testRejectedExactMatchingDoesNotContinueDensityLadder() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("ExactFallback.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<45 {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(index)
            )
        }

        let metadata = ProjectMetadata(
            title: "Exact fallback",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .fast,
                inputOrdering: .continuous,
                photoSelection: .useAllValidPhotos
            )
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(metadata, paths: paths)
        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try? self.writeFeatureDatabase(for: $0) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["local_vocab_retriever"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try? self.writeVocabularyOutput(for: $0) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(
                    exitCode: SIGSEGV,
                    terminationReason: .uncaughtSignal,
                    stdout: "",
                    stderr: "segmentation fault"
                ),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: args), "0")
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["local_vocab_retriever"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try? self.writeVocabularyOutput(for: $0) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: args), "1")
                    try? self.writeVerifiedPairResults(for: args, verifiedRows: 0)
                }
            ),
        ])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                skipTraining: true
            ),
            tooling: .init(runner: runner)
        )

        do {
            try await pipeline.run { _ in }
            XCTFail("Expected the exact matcher graph to remain disconnected")
        } catch {
            guard let failure = error as? CaptureConnectionFailure else {
                return XCTFail("Expected typed exhausted capture evidence, got \(error)")
            }
            XCTAssertEqual(failure.attempt.matcher, .exact)
            XCTAssertEqual(failure.attempt.recoveryLevel, .normal)
            XCTAssertLessThanOrEqual(
                failure.attempt.scheduledPairCount,
                DescriptorMatcherRecoveryPolicy.maximumExactRecoveryPairCount
            )
        }

        let commands = runner.calls.compactMap { $0.1.first }
        XCTAssertEqual(commands.filter { $0 == "feature_extractor" }.count, 1)
        XCTAssertEqual(commands.filter { $0 == "local_vocab_retriever" }.count, 1)
        XCTAssertEqual(commands.filter { $0 == "matches_importer" }.count, 2)
        let recovery = try PairGraphRecoveryStore.loadBound(
            from: paths.pairGraphRecoveryURL,
            expectedImageNames: selectedImageNames(in: paths),
            projectPaths: paths
        )
        XCTAssertEqual(
            recovery.attempts.map(\.artifact.recoveryLevel),
            [.normal, .normal]
        )
        XCTAssertEqual(recovery.attempts.map(\.artifact.matcher), [.faiss, .exact])
        XCTAssertEqual(recovery.attempts.map(\.artifact.outcome), [.failed, .rejected])
    }

    func testFailedVocabularyInvocationLeavesScheduledRecoveryEvidence() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent(
            "FailedVocabularyRecovery.easysplatproj",
            isDirectory: true
        )
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourcePhotos,
            withIntermediateDirectories: true
        )
        for index in 0..<61 {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(index)
            )
        }

        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(
            ProjectMetadata(
                title: "Failed vocabulary recovery",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    detailProfile: .fast,
                    inputOrdering: .unordered,
                    photoSelection: .useAllValidPhotos
                )
            ),
            paths: paths
        )
        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: ""
                ),
                onRun: { try? self.writeFeatureDatabase(for: $0) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["local_vocab_retriever"],
                result: .init(
                    exitCode: 1,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: "retrieval failed"
                )
            ),
        ])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                skipTraining: true
            ),
            tooling: .init(runner: runner)
        )

        do {
            try await pipeline.run { _ in }
            XCTFail("Expected local vocabulary retrieval to fail")
        } catch {
            XCTAssertTrue(runner.calls.contains { $0.1.first == "local_vocab_retriever" })
        }

        let recovery = try PairGraphRecoveryStore.load(
            from: paths.pairGraphRecoveryURL,
            projectPaths: paths
        )
        XCTAssertEqual(recovery.phase, .preparing)
        XCTAssertEqual(recovery.attempts, [])
        XCTAssertTrue(recovery.retrievalWasScheduled)
        XCTAssertFalse(recovery.usedLocalVocabularyRetrieval)
    }

    func testPlanningFailureIsNotMisreportedAsAMatcherExecution() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent(
            "PlanningEvidence.easysplatproj",
            isDirectory: true
        )
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<61 {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(index)
            )
        }

        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(
            ProjectMetadata(
                title: "Planning evidence",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    detailProfile: .fast,
                    inputOrdering: .unordered,
                    photoSelection: .useAllValidPhotos
                )
            ),
            paths: paths
        )
        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { arguments in
                    do {
                        try self.writeFeatureDatabase(for: arguments)
                    } catch {
                        XCTFail("Could not create feature database: \(error)")
                    }
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["local_vocab_retriever"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { arguments in
                    XCTAssertEqual(self.value(for: "--num_images", in: arguments), "20")
                    XCTAssertEqual(
                        self.value(for: "--returned_neighbor_count", in: arguments),
                        "8"
                    )
                    do {
                        try self.writeVocabularyOutput(for: arguments)
                    } catch {
                        XCTFail("Could not write empty retrieval result: \(error)")
                    }
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["local_vocab_retriever"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { arguments in
                    XCTAssertEqual(self.value(for: "--num_images", in: arguments), "40")
                    XCTAssertEqual(
                        self.value(for: "--returned_neighbor_count", in: arguments),
                        "16"
                    )
                    do {
                        try self.writeVocabularyOutput(for: arguments, connectQueries: true)
                    } catch {
                        XCTFail("Could not write connected retrieval result: \(error)")
                    }
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { arguments in
                    do {
                        try self.writeVerifiedPairResults(for: arguments)
                    } catch {
                        XCTFail("Could not write verified matches: \(error)")
                    }
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                stdoutLines: ["Retriangulation and Global bundle adjustment"],
                onRun: { _ in
                    do {
                        try self.writeSparseModel(at: projectURL)
                    } catch {
                        XCTFail("Could not write sparse model: \(error)")
                    }
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: 61 / 61\nPoints: 20\nObservations: 1220\nMean track length: 61.0\nMean reprojection error: 0.5\n",
                    stderr: ""
                )
            ),
        ])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                skipTraining: true
            ),
            tooling: .init(runner: runner)
        )
        try await pipeline.run { _ in }

        let geometry = try GeometryArtifactStore.load(
            from: paths.geometryManifestURL,
            projectPaths: paths
        )
        let measurement = try XCTUnwrap(geometry.pairGraph.measurement)
        XCTAssertEqual(measurement.matcherAttempts.count, 1)
        XCTAssertEqual(measurement.matcherAttempts.map(\.recoveryLevel), [.expanded])
        XCTAssertEqual(measurement.matcherAttempts.map(\.outcome), [.completed])
        XCTAssertEqual(
            measurement.matchingDurationSeconds,
            measurement.matcherAttempts.reduce(0) { $0 + $1.durationSeconds },
            accuracy: 1e-12
        )
        let pairEvidence = try PairGraphEvidenceStore.loadVerified(
            from: paths.pairGraphEvidenceURL,
            expectedImageNames: geometry.orderedImageNames,
            databaseURL: paths.colmapDatabaseURL,
            projectPaths: paths
        )
        XCTAssertNoThrow(try PairGraphEvidenceStore.validateWorkerExecution(
            pairEvidence,
            workerExecution: geometry.workerExecution
        ))
        XCTAssertEqual(geometry.workerExecution.matchingInvocations.count, 1)
        XCTAssertEqual(geometry.workerExecution.vocabularyRetrievalInvocations.count, 1)
        XCTAssertEqual(
            geometry.workerExecution.matchingInvocations[0].pairExecution?.attemptOrdinal,
            1
        )
        XCTAssertEqual(
            geometry.workerExecution.matchingInvocations[0].pairExecution?.pairListDigest,
            pairEvidence.pairListDigest
        )
    }

    func testZeroNeighborRetrievalReachesExhaustiveFaissWithoutStickyUsage() async throws {
        let temp = makeTempRoot()
        let fixture = try makePhotoRecoveryProject(
            in: temp,
            name: "ZeroNeighborExhaustiveRecovery",
            photoCount: 61
        )
        let run = makePhotoRecoveryPipeline(
            projectURL: fixture.projectURL,
            toolchain: fixture.toolchain,
            scripts: [
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["feature_extractor"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { try self.writeFeatureDatabase(for: $0) }
                ),
                noNeighborVocabularyScript(
                    colmapPath: fixture.toolchain.colmap.path
                ),
                noNeighborVocabularyScript(
                    colmapPath: fixture.toolchain.colmap.path
                ),
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["matches_importer"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { arguments in
                        XCTAssertEqual(
                            try self.pairListLines(for: arguments).count,
                            1_830
                        )
                        try self.writeVerifiedPairResults(for: arguments)
                    }
                ),
            ],
            stopAfterStage: .sfmMatching
        )

        try await run.pipeline.run { _ in }

        let commands = run.runner.calls.compactMap { $0.1.first }
        XCTAssertEqual(commands.filter { $0 == "local_vocab_retriever" }.count, 2)
        XCTAssertEqual(commands.filter { $0 == "matches_importer" }.count, 1)
        let evidence = try PairGraphEvidenceStore.load(
            from: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
        XCTAssertTrue(evidence.retrievalWasScheduled)
        XCTAssertFalse(evidence.usedLocalVocabularyRetrieval)
        XCTAssertEqual(evidence.attempts.map(\.artifact.recoveryLevel), [.maximum])
        XCTAssertNil(evidence.attempts.last?.retrieval)
        let worker = try GeometryWorkerExecutionArtifactStore.load(
            from: fixture.paths.workerExecutionURL,
            projectPaths: fixture.paths
        )
        XCTAssertTrue(worker.vocabularyRetrievalInvocations.isEmpty)
        XCTAssertEqual(worker.rejectedVocabularyRetrievalInvocations.count, 2)
        XCTAssertEqual(
            worker.rejectedVocabularyRetrievalInvocations.map(\.recoveryLevel),
            [.normal, .expanded]
        )
        XCTAssertEqual(worker.matchingInvocations.count, 1)
        XCTAssertNoThrow(try PairGraphEvidenceStore.validateWorkerExecution(
            evidence,
            workerExecution: worker
        ))
    }

    func testConnectedOrderedBaseMatchesNormallyWhenRetrievalFindsNoNovelNeighbors() async throws {
        let temp = makeTempRoot()
        let fixture = try makePhotoRecoveryProject(
            in: temp,
            name: "ConnectedOrderedZeroNeighbor",
            photoCount: 250,
            inputOrdering: .continuous,
            detailProfile: .balanced
        )
        let run = makePhotoRecoveryPipeline(
            projectURL: fixture.projectURL,
            toolchain: fixture.toolchain,
            scripts: [
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["feature_extractor"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { try self.writeFeatureDatabase(for: $0) }
                ),
                noNeighborVocabularyScript(
                    colmapPath: fixture.toolchain.colmap.path
                ),
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["matches_importer"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { arguments in
                        XCTAssertEqual(
                            try self.pairListLines(for: arguments).count,
                            1_745
                        )
                        try self.writeVerifiedPairResults(for: arguments)
                    }
                ),
            ],
            stopAfterStage: .sfmMatching
        )

        try await run.pipeline.run { _ in }

        let commands = run.runner.calls.compactMap { $0.1.first }
        XCTAssertEqual(commands.filter { $0 == "local_vocab_retriever" }.count, 1)
        XCTAssertEqual(commands.filter { $0 == "matches_importer" }.count, 1)
        let evidence = try PairGraphEvidenceStore.load(
            from: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
        XCTAssertEqual(evidence.attempts.map(\.artifact.recoveryLevel), [.normal])
        XCTAssertEqual(evidence.attempts.last?.scheduledPairs.count, 1_745)
        XCTAssertTrue(evidence.attempts.last?.retrieval?.directedPairLines.isEmpty == true)
        XCTAssertTrue(evidence.attempts.last?.retrieval?.queryOutcomes.allSatisfy {
            $0.status == .noRankedNeighbors
        } == true)
        XCTAssertTrue(evidence.retrievalWasScheduled)
        XCTAssertTrue(evidence.usedLocalVocabularyRetrieval)
        let worker = try GeometryWorkerExecutionArtifactStore.load(
            from: fixture.paths.workerExecutionURL,
            projectPaths: fixture.paths
        )
        XCTAssertEqual(worker.vocabularyRetrievalInvocations.count, 1)
        XCTAssertTrue(worker.rejectedVocabularyRetrievalInvocations.isEmpty)
        XCTAssertEqual(worker.matchingInvocations.count, 1)
    }

    func testExhaustedLargeRetrievalPreservesValidatedRejectionsAndFailsWithCaptureGuidance() async throws {
        let temp = makeTempRoot()
        let fixture = try makePhotoRecoveryProject(
            in: temp,
            name: "ZeroNeighborTerminalRecovery",
            photoCount: 251,
            detailProfile: .highDetail
        )
        let run = makePhotoRecoveryPipeline(
            projectURL: fixture.projectURL,
            toolchain: fixture.toolchain,
            scripts: [
                .init(
                    path: fixture.toolchain.colmap.path,
                    argsPrefix: ["feature_extractor"],
                    result: .init(
                        exitCode: 0,
                        terminationReason: .exit,
                        stdout: "",
                        stderr: ""
                    ),
                    onRun: { try self.writeFeatureDatabase(for: $0) }
                ),
                noNeighborVocabularyScript(
                    colmapPath: fixture.toolchain.colmap.path
                ),
                noNeighborVocabularyScript(
                    colmapPath: fixture.toolchain.colmap.path
                ),
                noNeighborVocabularyScript(
                    colmapPath: fixture.toolchain.colmap.path
                ),
            ]
        )

        let failure: CaptureRetrievalConnectionFailure
        do {
            try await run.pipeline.run { _ in }
            return XCTFail("Expected retrieval recovery to fail after the maximum policy.")
        } catch let caught as CaptureRetrievalConnectionFailure {
            failure = caught
        }

        XCTAssertEqual(failure.pairingPolicy, .unorderedRetrieval)
        XCTAssertEqual(failure.selectedViewCount, 251)
        XCTAssertEqual(failure.attempts.map(\.retrievalAttemptOrdinal), [1, 2, 3])
        XCTAssertEqual(failure.attempts.map(\.recoveryLevel), [.normal, .expanded, .maximum])
        XCTAssertEqual(failure.attempts.map { $0.retrieval.candidateCount }, [20, 40, 80])
        XCTAssertEqual(failure.attempts.map { $0.retrieval.returnedNeighborCount }, [8, 16, 32])
        XCTAssertTrue(failure.attempts.allSatisfy {
            $0.retrieval.queryOutcomes.contains { $0.status == .noRankedNeighbors }
        })

        let commands = run.runner.calls.compactMap { $0.1.first }
        XCTAssertEqual(commands.filter { $0 == "local_vocab_retriever" }.count, 3)
        XCTAssertFalse(commands.contains("matches_importer"))

        let worker = try GeometryWorkerExecutionArtifactStore.load(
            from: fixture.paths.workerExecutionURL,
            projectPaths: fixture.paths
        )
        XCTAssertTrue(worker.vocabularyRetrievalInvocations.isEmpty)
        XCTAssertTrue(worker.matchingInvocations.isEmpty)
        XCTAssertEqual(worker.rejectedVocabularyRetrievalInvocations, failure.attempts)

        let messages = run.pipeline.test_failureMessages(
            for: failure,
            stage: .sfmMatching
        )
        XCTAssertEqual(
            messages.userMessage,
            "EasySplat found separate parts of the capture. Add views between the gaps with clear shared detail, and keep the scene still."
        )
        for hiddenImplementationTerm in ["faiss", "colmap", "retrieval", "unordered", "graph"] {
            XCTAssertFalse(
                messages.userMessage.lowercased().contains(hiddenImplementationTerm)
            )
        }
        XCTAssertTrue(messages.debugMessage.contains("251 selected views"))
        XCTAssertTrue(messages.debugMessage.contains("retrieval attempt 1"))
        XCTAssertTrue(messages.debugMessage.contains("recovery normal"))
        XCTAssertTrue(messages.debugMessage.contains("20 candidates"))
        XCTAssertTrue(messages.debugMessage.contains("8 requested neighbors"))
        XCTAssertTrue(messages.debugMessage.contains("retrieval attempt 3"))
        XCTAssertTrue(messages.debugMessage.contains("recovery maximum"))
        XCTAssertTrue(messages.debugMessage.contains("80 candidates"))
        XCTAssertTrue(messages.debugMessage.contains("32 requested neighbors"))
    }

    func testRepeatedExpandedRetrievalTriesMaximumFaissBeforeExact() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent(
            "RepeatedRetrieval.easysplatproj",
            isDirectory: true
        )
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<251 {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(truncatingIfNeeded: index)
            )
        }

        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(
            ProjectMetadata(
                title: "Repeated retrieval",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    detailProfile: .highDetail,
                    inputOrdering: .unordered,
                    photoSelection: .useAllValidPhotos
                )
            ),
            paths: paths
        )
        let toolchain = try makeToolchain(root: temp)
        let lowQuality = "Registered images: 100 / 251\nPoints: 20\nObservations: 2000\nMean track length: 100.0\nMean reprojection error: 0.5\n"
        let accepted = "Registered images: 251 / 251\nPoints: 20\nObservations: 5020\nMean track length: 251.0\nMean reprojection error: 0.5\n"
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { arguments in
                    do {
                        try self.writeFeatureDatabase(for: arguments)
                    } catch {
                        XCTFail("Could not create feature database: \(error)")
                    }
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["local_vocab_retriever"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { arguments in
                    XCTAssertEqual(self.value(for: "--num_images", in: arguments), "20")
                    do {
                        try self.writeVocabularyOutput(for: arguments, connectQueries: true)
                    } catch {
                        XCTFail("Could not write normal retrieval result: \(error)")
                    }
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { arguments in
                    XCTAssertEqual(
                        self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: arguments),
                        "0"
                    )
                    do {
                        try self.writeVerifiedPairResults(for: arguments)
                    } catch {
                        XCTFail("Could not write normal verified matches: \(error)")
                    }
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                stdoutLines: ["Retriangulation and Global bundle adjustment"],
                onRun: { _ in
                    do {
                        try self.writeSparseModel(
                            at: projectURL,
                            registeredImageCount: 100
                        )
                    } catch {
                        XCTFail("Could not write first sparse model: \(error)")
                    }
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: lowQuality,
                    stderr: ""
                )
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                stdoutLines: ["Retriangulation and Global bundle adjustment"],
                onRun: { arguments in
                    XCTAssertEqual(
                        self.value(for: "--Mapper.ba_global_frames_ratio", in: arguments),
                        "1.1"
                    )
                    do {
                        try self.writeSparseModel(
                            at: projectURL,
                            registeredImageCount: 100
                        )
                    } catch {
                        XCTFail("Could not write cadence-retry sparse model: \(error)")
                    }
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: lowQuality,
                    stderr: ""
                )
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["local_vocab_retriever"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { arguments in
                    XCTAssertEqual(self.value(for: "--num_images", in: arguments), "40")
                    do {
                        try self.writeVocabularyOutput(for: arguments, connectQueries: true)
                    } catch {
                        XCTFail("Could not write expanded retrieval result: \(error)")
                    }
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["local_vocab_retriever"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { arguments in
                    XCTAssertEqual(self.value(for: "--num_images", in: arguments), "80")
                    XCTAssertEqual(
                        self.value(for: "--returned_neighbor_count", in: arguments),
                        "32"
                    )
                    guard let queryPath = self.value(
                        for: "--query_image_list_path",
                        in: arguments
                    ) else {
                        return XCTFail("Maximum retrieval is missing its query list")
                    }
                    do {
                        let queryNames = try String(contentsOfFile: queryPath, encoding: .utf8)
                            .split(whereSeparator: \.isWhitespace)
                            .map(String.init)
                        var pairs = zip(queryNames, queryNames.dropFirst()).map {
                            "\($0.0) \($0.1)"
                        }
                        if queryNames.count > 2 {
                            pairs.append("\(queryNames[0]) \(queryNames[2])")
                        }
                        try self.writeVocabularyOutput(for: arguments, pairLines: pairs)
                    } catch {
                        XCTFail("Could not write maximum retrieval result: \(error)")
                    }
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { arguments in
                    XCTAssertEqual(
                        self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: arguments),
                        "0"
                    )
                    do {
                        try self.writeVerifiedPairResults(for: arguments)
                    } catch {
                        XCTFail("Could not write maximum verified matches: \(error)")
                    }
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                stdoutLines: ["Retriangulation and Global bundle adjustment"],
                onRun: { _ in
                    do {
                        try self.writeSparseModel(at: projectURL)
                    } catch {
                        XCTFail("Could not write accepted sparse model: \(error)")
                    }
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: accepted,
                    stderr: ""
                )
            ),
        ])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                skipTraining: true
            ),
            tooling: .init(runner: runner)
        )
        try await pipeline.run { _ in }

        let commands = runner.calls.compactMap { $0.1.first }
        XCTAssertEqual(commands.filter { $0 == "feature_extractor" }.count, 1)
        XCTAssertEqual(commands.filter { $0 == "local_vocab_retriever" }.count, 3)
        XCTAssertEqual(commands.filter { $0 == "matches_importer" }.count, 2)
        XCTAssertEqual(commands.filter { $0 == "mapper" }.count, 3)
        let geometry = try GeometryArtifactStore.load(
            from: paths.geometryManifestURL,
            projectPaths: paths
        )
        let attempts = try XCTUnwrap(geometry.pairGraph.measurement?.matcherAttempts)
        XCTAssertEqual(attempts.map(\.recoveryLevel), [.normal, .maximum])
        XCTAssertEqual(attempts.map(\.matcher), [.faiss, .faiss])
        XCTAssertEqual(attempts.map(\.outcome), [.completed, .completed])
    }

    func testExplicitSharedCameraRejectsMixedImageDimensionsBeforeFeatureExtraction() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("MixedDimensionsRetry.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<30 {
            let dimensions = index.isMultiple(of: 2) ? (32, 24) : (40, 30)
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                width: dimensions.0,
                height: dimensions.1,
                value: UInt8((index * 7) % 256)
            )
        }

        let metadata = ProjectMetadata(
            title: "Mixed dimensions retry",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .fast,
                cameraGrouping: .sameCameraAndLens,
                inputOrdering: .continuous,
                photoSelection: .useAllValidPhotos
            )
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(metadata, paths: paths)
        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { try? self.writeFeatureDatabase(for: $0) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["local_vocab_retriever"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { try? self.writeVocabularyOutput(for: $0) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["matches_importer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { try? self.writeVerifiedPairResults(for: $0) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), stdoutLines: ["Retriangulation and Global bundle adjustment"], onRun: { _ in
                try? self.writeSparseModel(at: projectURL)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 30 / 30\nPoints: 20\nObservations: 600\nMean track length: 30.0\nMean reprojection error: 0.5\n", stderr: ""), onRun: nil),
        ])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                skipTraining: true
            ),
            tooling: .init(runner: runner)
        )

        do {
            try await pipeline.run { _ in }
            XCTFail("Expected incompatible shared-camera dimensions to fail")
        } catch {
            guard case .incompatibleSharedCameraDimensions =
                error as? PipelineRunner.PipelineError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let featureCalls = runner.calls.filter { $0.1.first == "feature_extractor" }
        XCTAssertEqual(featureCalls.count, 0, "Calls: \(runner.calls)")
    }

    func testLargeUnorderedColmapMatchingUsesBoundedRetrievalPairs() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("UnorderedRetrieval.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<120 {
            try writeRetrievalTestImage(
                url: sourcePhotos.appendingPathComponent(String(format: "img_%03d.jpg", index)),
                index: index
            )
        }
        let metadata = ProjectMetadata(
            title: "Unordered retrieval",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(
                detailProfile: .highDetail,
                inputOrdering: .unordered,
                photoSelection: .useAllValidPhotos
            )
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(metadata, paths: paths)
        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { try? self.writeFeatureDatabase(for: $0) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["local_vocab_retriever"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                XCTAssertEqual(self.value(for: "--num_images", in: args), "20")
                XCTAssertEqual(self.value(for: "--returned_neighbor_count", in: args), "8")
                try? self.writeVocabularyOutput(for: args, connectQueries: true)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["matches_importer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let path = self.value(for: "--match_list_path", in: args),
                      let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                    return XCTFail("Retrieval pair list was not readable")
                }
                let pairs = text.split(separator: "\n")
                XCTAssertLessThanOrEqual(pairs.count, 960)
                XCTAssertGreaterThanOrEqual(pairs.count, 119)
                try? self.writeVerifiedPairResults(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), stdoutLines: ["Retriangulation and Global bundle adjustment"], onRun: { _ in
                try? self.writeSparseModel(at: projectURL)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 120 / 120\nPoints: 20\nObservations: 2400\nMean track length: 120.0\n", stderr: ""), onRun: nil),
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap,
                skipTraining: true
            ),
            tooling: .init(runner: runner)
        )
        try await pipeline.run { _ in }

        let commands = runner.calls.compactMap { $0.1.first }
        XCTAssertTrue(commands.contains("local_vocab_retriever"))
        XCTAssertTrue(commands.contains("matches_importer"))
        let geometry = try GeometryArtifactStore.load(
            from: paths.geometryManifestURL,
            projectPaths: paths
        )
        let evidence = try PairGraphEvidenceStore.loadVerified(
            from: paths.pairGraphEvidenceURL,
            expectedImageNames: geometry.orderedImageNames,
            databaseURL: paths.colmapDatabaseURL,
            projectPaths: paths
        )
        let resolvedPlan = try XCTUnwrap(
            ProjectMetadataStore.load(from: paths.metadataURL).resolvedRunPlan
        )
        let retrieval = try XCTUnwrap(evidence.attempts.last?.retrieval)
        XCTAssertEqual(retrieval.engine, resolvedPlan.retrievalEngine)
        XCTAssertEqual(retrieval.queryStride, resolvedPlan.retrievalQueryStride)
        XCTAssertEqual(retrieval.candidateCount, resolvedPlan.retrievalCandidateCount)
        XCTAssertEqual(retrieval.returnedNeighborCount, resolvedPlan.retrievalNeighborCount)
        XCTAssertNoThrow(try PairGraphEvidenceStore.validateSchedule(
            evidence,
            resolvedPlan: resolvedPlan,
            groups: [ColmapPairGroup(imageNames: evidence.imageNames, isVideo: false)]
        ))
    }

    func testPipelineFailureClearsRunStartMarker() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("TestFail.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<8 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "TestFail",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(metadata, paths: paths)

        let toolchain = try makeToolchain(root: temp)
        let powerAssertion = RecordingPowerAssertion()
        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "feature extraction failed"), onRun: { _ in
                XCTAssertEqual(powerAssertion.active, 1, "The assertion must remain active through a failing subprocess.")
            })
        ])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, candidateRoute: .colmap),
            tooling: .init(runner: runner),
            powerAssertion: powerAssertion
        )

        await XCTAssertThrowsErrorAsync({
            try await pipeline.run { _ in }
        }, errorHandler: { _ in })

        XCTAssertEqual(powerAssertion.begun, 1, "A failed run still holds exactly one idle-sleep assertion.")
        XCTAssertEqual(powerAssertion.released, 1, "A failed run must release the idle-sleep assertion on the throw path.")
        XCTAssertEqual(powerAssertion.active, 0)

        let failedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertNil(failedMetadata.lastRunStartedAt, "Failed runs should clear lastRunStartedAt.")
        XCTAssertNotNil(failedMetadata.state.lastError)
        XCTAssertNotNil(
            failedMetadata.lastFailureAt,
            "PipelineRunner.emitFailure must preserve the real failure time for diagnostics."
        )
    }

    func testPipelineExplicitDa3FailureDoesNotFallbackToOtherBackends() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("StrictDa3.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<3 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "StrictDa3",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .fast,
                cameraGrouping: .sameCameraAndLens
            )
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(metadata, paths: paths)

        let toolchain = try makeToolchain(root: temp, createDa3Files: true)
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.da3.sfmTool.path,
                argsPrefix: ["--images"],
                result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "da3 native export failed"),
                onRun: nil
            )
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, candidateRoute: .da3, skipTraining: true),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync({
            try await pipeline.run { _ in }
        })

        XCTAssertEqual(runner.calls.count, 1)
        XCTAssertEqual(runner.calls.first?.0, toolchain.da3.sfmTool.path)
        XCTAssertFalse(runner.calls.contains(where: { $0.0 == toolchain.colmap.path }))
    }

    func testPipelineCanTrainWithNativeMsplat() async throws {
        let temp = makeTempRoot()

        let projectURL = temp.appendingPathComponent("Msplat.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<12 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "Msplat",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(detailProfile: .fast)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(metadata, paths: paths)

        let toolchain = try makeToolchain(root: temp, createMsplatFile: true)
        let plySizeProbe = temp.appendingPathComponent("msplat-size-probe.ply")
        try TestFileBuilder.writeMinimalPly(at: plySizeProbe, vertexCount: 1_800)
        let msplatOutputBytes = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: plySizeProbe.path)[.size] as? NSNumber)?.int64Value
        )
        try FileManager.default.removeItem(at: plySizeProbe)
        let inputDigest = String(repeating: "1", count: 64)
        let geometryDigest = String(repeating: "2", count: 64)
        let trainerDigest = String(repeating: "3", count: 64)
        let payloadDigest = String(repeating: "4", count: 64)
        let generation = "00000000-" + String(repeating: "5", count: 64)
        let memoryBudgetBytes = automaticTrainingMemoryBudgetBytes
        let msplatEvents = """
        {"camera_count":12,"checkpoint_schema":3,"event":"started","geometry_digest":"\(geometryDigest)","initial_gaussian_count":1500,"input_digest":"\(inputDigest)","iteration":0,"iteration_limit":3000,"memory_budget_bytes":\(memoryBudgetBytes),"payload_schema":2,"plateau_window":400,"profile":"fast","raster_exact_buffer_bytes_added":0,"raster_exact_buffer_growth_count":0,"raster_exact_fallback_elapsed_seconds":0,"raster_fallback_count":0,"raster_peak_exact_intersection_capacity":0,"raster_replay_elapsed_seconds":0,"resumed":false,"schema_version":2,"seed":42,"sequence":1,"trainer_build_digest":"\(trainerDigest)","version":"1.1.3 (git 106499b)"}
        {"checkpoint_generation":"\(generation)","checkpoint_payload_bytes":128,"checkpoint_payload_sha256":"\(payloadDigest)","dropped_intersection_count":0,"event":"checkpoint_completed","gaussian_count":1500,"geometry_digest":"\(geometryDigest)","input_digest":"\(inputDigest)","iteration":0,"memory_budget_bytes":\(memoryBudgetBytes),"peak_memory_bytes":268435456,"profile":"fast","raster_exact_buffer_bytes_added":0,"raster_exact_buffer_growth_count":0,"raster_exact_fallback_elapsed_seconds":0,"raster_fallback_count":0,"raster_peak_exact_intersection_capacity":0,"raster_replay_elapsed_seconds":0,"schema_version":2,"seed":42,"sequence":2,"trainer_build_digest":"\(trainerDigest)","version":"1.1.3 (git 106499b)"}
        {"dropped_intersection_count":0,"elapsed_seconds":2,"event":"completed","gaussian_count":1800,"geometry_digest":"\(geometryDigest)","input_digest":"\(inputDigest)","iteration":3000,"iteration_limit":3000,"memory_budget_bytes":\(memoryBudgetBytes),"output_bytes":\(msplatOutputBytes),"peak_memory_bytes":536870912,"plateau_window":400,"profile":"fast","raster_exact_buffer_bytes_added":0,"raster_exact_buffer_growth_count":0,"raster_exact_fallback_elapsed_seconds":0,"raster_fallback_count":0,"raster_peak_exact_intersection_capacity":0,"raster_replay_elapsed_seconds":0,"scene_center":[0,0,0],"scene_radius":2.5,"schema_version":2,"seed":42,"sequence":3,"stop_reason":"iteration_limit","trainer_build_digest":"\(trainerDigest)","version":"1.1.3 (git 106499b)"}
        """ + "\n"
        var msplatDatasetPath: String?
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try? self.writeFeatureDatabase(for: $0) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try? self.writeVerifiedPairResults(for: $0) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                stdoutLines: ["Retriangulation and Global bundle adjustment"],
                onRun: { _ in
                    try? self.writeSparseModel(at: projectURL)
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: 12 / 12\nMean reprojection error: 1.0\n",
                    stderr: ""
                ),
                onRun: nil
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    guard let outputPath = self.value(for: "--output_path", in: args) else { return }
                    let out = URL(fileURLWithPath: outputPath, isDirectory: true)
                    try? self.writeMinimalColmapBinaryModel(
                        at: out,
                        imageNames: (0..<12).map { String(format: "frame_%06d.jpg", $0) }
                    )
                }
            ),
            .init(
                path: toolchain.msplat.path,
                argsPrefix: ["--dataset"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                stdoutLinesProvider: { args in
                    guard let datasetArg = args.dropFirst().first else { return [] }
                    let dataset = URL(fileURLWithPath: datasetArg, isDirectory: true)
                    guard let identity = try? MsplatDatasetIdentity.compute(
                        imageDirectory: dataset.appendingPathComponent("images", isDirectory: true),
                        sparseDirectory: dataset.appendingPathComponent("sparse/0", isDirectory: true)
                    ) else { return [] }
                    return msplatEvents
                        .replacingOccurrences(of: inputDigest, with: identity.inputDigest)
                        .replacingOccurrences(of: geometryDigest, with: identity.geometryDigest)
                        .split(separator: "\n")
                        .map(String.init)
                },
                onRun: { args in
                    guard let datasetArg = args.dropFirst().first,
                          let outputArg = self.value(for: "--output", in: args),
                          let checkpointArg = self.value(for: "--checkpoint", in: args) else { return }
                    msplatDatasetPath = datasetArg
                    let dataset = URL(fileURLWithPath: datasetArg, isDirectory: true)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: dataset.appendingPathComponent("sparse/0/cameras.bin").path))
                    XCTAssertTrue(args.contains("fast"))
                    XCTAssertFalse(args.contains("--num-iters"))
                    XCTAssertEqual(
                        self.value(for: "--memory-budget-bytes", in: args),
                        String(memoryBudgetBytes)
                    )
                    try? TestFileBuilder.writeMinimalPly(
                        at: URL(fileURLWithPath: outputArg),
                        vertexCount: 1_800
                    )
                    try? FileManager.default.createDirectory(
                        at: URL(fileURLWithPath: checkpointArg, isDirectory: true),
                        withIntermediateDirectories: true
                    )
                }
            )
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .colmap
            ),
            tooling: .init(
                runner: runner,
                trainingResourceObserver: TestTrainingResourceObserver()
            )
        )

        try await pipeline.run { _ in }

        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.msplat.path }))
        XCTAssertNotNil(msplatDatasetPath)
        let output = projectURL.appendingPathComponent("Output/splat.ply")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let completedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let plan = try XCTUnwrap(completedMetadata.resolvedRunPlan)
        let trainingArtifact = try TrainingArtifactStore.load(
            from: paths.trainingManifestURL,
            projectPaths: paths
        )
        XCTAssertEqual(trainingArtifact.completionStatus, .completed)
        XCTAssertEqual(plan.trainerMemoryBudgetBytes, memoryBudgetBytes)
        XCTAssertEqual(trainingArtifact.memoryBudgetBytes, memoryBudgetBytes)
        XCTAssertEqual(trainingArtifact.rasterFallbackCount, 0)
        XCTAssertEqual(trainingArtifact.droppedIntersectionCount, 0)
        XCTAssertEqual(trainingArtifact.trainerBuildDigest, trainerDigest)
        XCTAssertEqual(trainingArtifact.outputPath, "Output/splat.ply")
        XCTAssertEqual(trainingArtifact.iterationLimit, plan.trainerIterationLimit)
        XCTAssertEqual(trainingArtifact.plateauWindow, plan.plateauWindow)
        XCTAssertEqual(trainingArtifact.cameraOrderSeed, plan.runSeed)
        XCTAssertEqual(trainingArtifact.peakMemoryBytes, 536_870_912)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.msplatCheckpointURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.msplatOutputURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: paths.trainingURL.appendingPathComponent("msplat_dataset").path
            )
        )
        XCTAssertEqual(
            try TrainingArtifactStore.load(
                from: paths.trainingManifestURL,
                projectPaths: paths
            ),
            trainingArtifact
        )
    }

    func testCompletedTrainingCleanupRejectsSymlinkedTrainingParent() throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("CleanupSymlink.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()

        let externalTraining = temp.appendingPathComponent("ExternalTraining", isDirectory: true)
        let externalDataset = externalTraining.appendingPathComponent("msplat_dataset", isDirectory: true)
        let externalOutput = externalTraining.appendingPathComponent("msplat/splat.ply")
        try FileManager.default.createDirectory(at: externalDataset, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: externalOutput.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let marker = externalDataset.appendingPathComponent("keep.txt")
        try Data("outside project".utf8).write(to: marker)
        try TestFileBuilder.writeMinimalPly(at: externalOutput)

        try FileManager.default.removeItem(at: paths.trainingURL)
        try FileManager.default.createSymbolicLink(
            at: paths.trainingURL,
            withDestinationURL: externalTraining
        )

        let toolchain = try makeToolchain(root: temp)
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain)
        )

        XCTAssertThrowsError(
            try pipeline.removeDisposableCompletedTrainingPayload(paths: paths)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalOutput.path))
    }

    func testPipelineCancellationRestartsFreshWhenNativeRejectsCheckpoint() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("ResumeMsplat.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<12 {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(index)
            )
        }
        var metadata = ProjectMetadata(
            title: "Resume msplat",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(detailProfile: .fast)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        metadata = try saveFixtureMetadata(metadata, paths: paths)
        metadata.resolvedRunPlan = resolvedFixturePlan(
            input: metadata.input,
            options: metadata.requestedRunOptions
        )
        try persistCurrentSelectedPhotoFixture(
            sources: (0..<3).map {
                paths.importedPhotosURL.appendingPathComponent(
                    String(format: "photo-%04d.jpg", $0)
                )
            },
            paths: paths,
            plan: try XCTUnwrap(metadata.resolvedRunPlan)
        )
        try writeCompletedColmapDatabase(paths: paths)
        let sparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        try "1 SIMPLE_PINHOLE 640 480 500 320 240\n".write(
            to: sparse.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )
        try """
        1 1 0 0 0 0 0 0 1 frame_000000.jpg
        320 240 1
        2 1 0 0 0 0 0 0 1 frame_000001.jpg
        320 240 1
        3 1 0 0 0 0 0 0 1 frame_000002.jpg
        320 240 1
        """.write(
            to: sparse.appendingPathComponent("images.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "1 0 0 1 128 128 128 0.5 1 0 2 0 3 0\n".write(
            to: sparse.appendingPathComponent("points3D.txt"),
            atomically: true,
            encoding: .utf8
        )
        try writeMinimalColmapBinaryModel(at: sparse, imageNames: (0..<3).map {
            String(format: "frame_%06d.jpg", $0)
        })
        let toolchain = try makeToolchain(root: temp, createMsplatFile: true)
        try persistGeometryArtifactFixture(
            metadata: &metadata,
            paths: paths,
            runtimeClosure: try ColmapRunner().captureRuntimeClosure(
                colmapPath: toolchain.colmap
            )
        )
        let geometry = try GeometryArtifactStore.load(
            from: paths.geometryManifestURL,
            projectPaths: paths,
            expectedInput: metadata.input
        )
        let identitySparse = try makeMsplatIdentitySparseFixture(
            from: sparse,
            under: paths.trainingURL,
            canonicalOrientation: geometry.canonicalOrientation
        )
        let datasetIdentity = try MsplatDatasetIdentity.compute(
            imageFiles: try FileManager.default.contentsOfDirectory(
                at: paths.framesSelectedURL,
                includingPropertiesForKeys: nil
            ),
            sparseDirectory: identitySparse
        )
        let memoryBudgetBytes = automaticTrainingMemoryBudgetBytes
        let receipt = try makeMsplatCheckpointFixture(
            at: paths.msplatCheckpointURL,
            iteration: 500,
            profile: "fast",
            iterationLimit: 3_000,
            plateauWindow: 400,
            inputDigest: datasetIdentity.inputDigest,
            geometryDigest: datasetIdentity.geometryDigest,
            memoryBudgetBytes: memoryBudgetBytes
        )
        let initialGeneration = "00000000-" + String(repeating: "5", count: 64)
        let interruptedEvents = """
        {"camera_count":8,"checkpoint_schema":3,"event":"started","geometry_digest":"\(receipt.geometryDigest)","initial_gaussian_count":750,"input_digest":"\(receipt.inputDigest)","iteration":0,"iteration_limit":3000,"memory_budget_bytes":\(memoryBudgetBytes),"payload_schema":2,"plateau_window":400,"profile":"fast","raster_exact_buffer_bytes_added":0,"raster_exact_buffer_growth_count":0,"raster_exact_fallback_elapsed_seconds":0,"raster_fallback_count":0,"raster_peak_exact_intersection_capacity":0,"raster_replay_elapsed_seconds":0,"resumed":false,"schema_version":2,"seed":42,"sequence":1,"trainer_build_digest":"\(receipt.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
        {"checkpoint_generation":"\(initialGeneration)","checkpoint_payload_bytes":128,"checkpoint_payload_sha256":"\(String(repeating: "4", count: 64))","dropped_intersection_count":0,"event":"checkpoint_completed","gaussian_count":750,"geometry_digest":"\(receipt.geometryDigest)","input_digest":"\(receipt.inputDigest)","iteration":0,"memory_budget_bytes":\(memoryBudgetBytes),"peak_memory_bytes":\(receipt.peakMemoryBytes),"profile":"fast","raster_exact_buffer_bytes_added":0,"raster_exact_buffer_growth_count":0,"raster_exact_fallback_elapsed_seconds":0,"raster_fallback_count":0,"raster_peak_exact_intersection_capacity":0,"raster_replay_elapsed_seconds":0,"schema_version":2,"seed":42,"sequence":2,"trainer_build_digest":"\(receipt.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
        {"elapsed_seconds":2,"eta_seconds":20,"event":"progress","gaussian_count":750,"iteration":500,"iteration_limit":3000,"iterations_per_second":250,"schema_version":2,"sequence":3}
        {"checkpoint_generation":"\(receipt.generation)","checkpoint_payload_bytes":\(receipt.payloadBytes),"checkpoint_payload_sha256":"\(receipt.payloadSHA256)","dropped_intersection_count":0,"event":"checkpoint_completed","gaussian_count":\(receipt.gaussianCount),"geometry_digest":"\(receipt.geometryDigest)","input_digest":"\(receipt.inputDigest)","iteration":\(receipt.iteration),"memory_budget_bytes":\(memoryBudgetBytes),"peak_memory_bytes":\(receipt.peakMemoryBytes),"profile":"fast","raster_exact_buffer_bytes_added":\(receipt.rasterExactBufferBytesAdded),"raster_exact_buffer_growth_count":\(receipt.rasterExactBufferGrowthCount),"raster_exact_fallback_elapsed_seconds":\(receipt.rasterExactFallbackElapsedSeconds),"raster_fallback_count":\(receipt.rasterFallbackCount),"raster_peak_exact_intersection_capacity":\(receipt.rasterPeakExactIntersectionCapacity),"raster_replay_elapsed_seconds":\(receipt.rasterReplayElapsedSeconds),"schema_version":2,"seed":42,"sequence":4,"trainer_build_digest":"\(receipt.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
        {"event":"cancellation_requested","iteration":575,"schema_version":2,"sequence":5,"signal":2}
        {"checkpoint_generation":"\(receipt.generation)","checkpoint_iteration":\(receipt.iteration),"checkpoint_payload_sha256":"\(receipt.payloadSHA256)","dropped_intersection_count":0,"event":"cancelled","geometry_digest":"\(receipt.geometryDigest)","input_digest":"\(receipt.inputDigest)","iteration":575,"memory_budget_bytes":\(memoryBudgetBytes),"raster_exact_buffer_bytes_added":\(receipt.rasterExactBufferBytesAdded),"raster_exact_buffer_growth_count":\(receipt.rasterExactBufferGrowthCount),"raster_exact_fallback_elapsed_seconds":\(receipt.rasterExactFallbackElapsedSeconds),"raster_fallback_count":\(receipt.rasterFallbackCount),"raster_peak_exact_intersection_capacity":\(receipt.rasterPeakExactIntersectionCapacity),"raster_replay_elapsed_seconds":\(receipt.rasterReplayElapsedSeconds),"schema_version":2,"sequence":6}
        """ + "\n"

        let firstBacking = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["model_converter"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let outputPath = self.value(for: "--output_path", in: args) else { return }
                let output = URL(fileURLWithPath: outputPath, isDirectory: true)
                try? self.writeMinimalColmapBinaryModel(
                    at: output,
                    imageNames: (0..<3).map { String(format: "frame_%06d.jpg", $0) }
                )
            }),
        ])
        let cancellingRunner = CheckpointCancellingSubprocessRunner(
            backing: firstBacking,
            launchPath: toolchain.msplat.path,
            events: interruptedEvents
        )
        let firstPipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, candidateRoute: .colmap),
            tooling: .init(
                runner: cancellingRunner,
                trainingResourceObserver: TestTrainingResourceObserver()
            )
        )

        do {
            try await firstPipeline.run(resumeFrom: .sfmMapping) { _ in }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
        let interruptedArtifact = try TrainingArtifactStore.load(
            from: paths.trainingManifestURL,
            projectPaths: paths
        )
        XCTAssertEqual(interruptedArtifact.completionStatus, .checkpointed)
        XCTAssertEqual(interruptedArtifact.completedIteration, 500)
        XCTAssertEqual(interruptedArtifact.checkpointDigest, receipt.payloadSHA256)
        XCTAssertEqual(interruptedArtifact.peakMemoryBytes, receipt.peakMemoryBytes)
        XCTAssertEqual(interruptedArtifact.memoryBudgetBytes, memoryBudgetBytes)
        XCTAssertEqual(interruptedArtifact.rasterFallbackCount, 0)
        XCTAssertEqual(interruptedArtifact.droppedIntersectionCount, 0)

        let outputProbe = temp.appendingPathComponent("resume-output-probe.ply")
        try TestFileBuilder.writeMinimalPly(at: outputProbe, vertexCount: 1_400)
        let outputBytes = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: outputProbe.path)[.size] as? NSNumber)?.int64Value
        )
        try FileManager.default.removeItem(at: outputProbe)
        let freshEvents = """
        {"camera_count":8,"checkpoint_schema":3,"event":"started","geometry_digest":"\(receipt.geometryDigest)","initial_gaussian_count":\(receipt.gaussianCount),"input_digest":"\(receipt.inputDigest)","iteration":0,"iteration_limit":3000,"memory_budget_bytes":\(memoryBudgetBytes),"payload_schema":2,"plateau_window":400,"profile":"fast","raster_exact_buffer_bytes_added":0,"raster_exact_buffer_growth_count":0,"raster_exact_fallback_elapsed_seconds":0,"raster_fallback_count":0,"raster_peak_exact_intersection_capacity":0,"raster_replay_elapsed_seconds":0,"resumed":false,"schema_version":2,"seed":42,"sequence":1,"trainer_build_digest":"\(receipt.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
        {"checkpoint_generation":"\(initialGeneration)","checkpoint_payload_bytes":128,"checkpoint_payload_sha256":"\(String(repeating: "4", count: 64))","dropped_intersection_count":0,"event":"checkpoint_completed","gaussian_count":\(receipt.gaussianCount),"geometry_digest":"\(receipt.geometryDigest)","input_digest":"\(receipt.inputDigest)","iteration":0,"memory_budget_bytes":\(memoryBudgetBytes),"peak_memory_bytes":\(receipt.peakMemoryBytes),"profile":"fast","raster_exact_buffer_bytes_added":0,"raster_exact_buffer_growth_count":0,"raster_exact_fallback_elapsed_seconds":0,"raster_fallback_count":0,"raster_peak_exact_intersection_capacity":0,"raster_replay_elapsed_seconds":0,"schema_version":2,"seed":42,"sequence":2,"trainer_build_digest":"\(receipt.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
        {"elapsed_seconds":4,"eta_seconds":0,"event":"progress","gaussian_count":1400,"iteration":3000,"iteration_limit":3000,"iterations_per_second":1600,"schema_version":2,"sequence":3}
        {"dropped_intersection_count":0,"elapsed_seconds":4,"event":"completed","gaussian_count":1400,"geometry_digest":"\(receipt.geometryDigest)","input_digest":"\(receipt.inputDigest)","iteration":3000,"iteration_limit":3000,"memory_budget_bytes":\(memoryBudgetBytes),"output_bytes":\(outputBytes),"peak_memory_bytes":536870912,"plateau_window":400,"profile":"fast","raster_exact_buffer_bytes_added":0,"raster_exact_buffer_growth_count":0,"raster_exact_fallback_elapsed_seconds":0,"raster_fallback_count":0,"raster_peak_exact_intersection_capacity":0,"raster_replay_elapsed_seconds":0,"scene_center":[0,0,0],"scene_radius":2.5,"schema_version":2,"seed":42,"sequence":4,"stop_reason":"iteration_limit","trainer_build_digest":"\(receipt.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
        """ + "\n"
        let secondRunner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["model_converter"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let outputPath = self.value(for: "--output_path", in: args) else { return }
                let output = URL(fileURLWithPath: outputPath, isDirectory: true)
                try? self.writeMinimalColmapBinaryModel(
                    at: output,
                    imageNames: (0..<3).map { String(format: "frame_%06d.jpg", $0) }
                )
            }),
            .init(
                path: toolchain.msplat.path,
                argsPrefix: ["--dataset"],
                result: .init(
                    exitCode: 78,
                    terminationReason: .exit,
                    stdout: "{\"event\":\"resume_rejected\",\"reason\":\"geometry_changed\",\"schema_version\":2,\"sequence\":1}\n",
                    stderr: "checkpoint geometry no longer matches"
                ),
                onRun: nil
            ),
            .init(path: toolchain.msplat.path, argsPrefix: ["--dataset"], result: .init(exitCode: 0, terminationReason: .exit, stdout: freshEvents, stderr: ""), onRun: { args in
                guard let outputPath = self.value(for: "--output", in: args) else { return }
                try? TestFileBuilder.writeMinimalPly(
                    at: URL(fileURLWithPath: outputPath),
                    vertexCount: 1_400
                )
            }),
        ])
        let secondPipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, candidateRoute: .colmap),
            tooling: .init(
                runner: secondRunner,
                trainingResourceObserver: TestTrainingResourceObserver()
            )
        )

        try await secondPipeline.run(resumeFrom: .sfmMapping) { _ in }

        let trainingCalls = secondRunner.calls.filter { $0.0 == toolchain.msplat.path }
        XCTAssertEqual(trainingCalls.count, 2)
        XCTAssertEqual(value(for: "--resume", in: trainingCalls[0].1), paths.msplatCheckpointURL.path)
        XCTAssertNil(value(for: "--resume", in: trainingCalls[1].1))
        let completedArtifact = try TrainingArtifactStore.load(
            from: paths.trainingManifestURL,
            projectPaths: paths
        )
        XCTAssertEqual(completedArtifact.completionStatus, .completed)
        XCTAssertEqual(completedArtifact.completedIteration, 3_000)
        XCTAssertEqual(completedArtifact.peakMemoryBytes, 536_870_912)
        XCTAssertEqual(
            ProjectArtifactValidator.validatePlyFile(
                at: paths.outputURL.appendingPathComponent("splat.ply")
            ),
            .valid
        )
    }

    func testBalancedRetryPinsNativeTrainerFromCheckpointArtifactAfterFailure() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("BalancedRetry.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<3 {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(index * 40)
            )
        }
        let requestedOptions = RequestedRunOptions(detailProfile: .balanced)
        var metadata = try saveFixtureMetadata(
            ProjectMetadata(
                title: "Balanced retry",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: requestedOptions,
                state: PipelineState(stage: .sfmMapping, lastError: nil)
            ),
            paths: paths
        )
        let resolvedPlan = resolvedFixturePlan(
            input: metadata.input,
            options: requestedOptions
        )
        metadata.resolvedRunPlan = resolvedPlan
        try persistCurrentSelectedPhotoFixture(
            sources: (0..<3).map {
                paths.importedPhotosURL.appendingPathComponent(
                    String(format: "photo-%04d.jpg", $0)
                )
            },
            paths: paths,
            plan: resolvedPlan
        )
        try writeCompletedColmapDatabase(paths: paths)
        let sparse = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        try "1 SIMPLE_PINHOLE 640 480 500 320 240\n".write(
            to: sparse.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )
        try """
        1 1 0 0 0 0 0 0 1 frame_000000.jpg
        320 240 1
        2 1 0 0 0 0 0 0 1 frame_000001.jpg
        320 240 1
        3 1 0 0 0 0 0 0 1 frame_000002.jpg
        320 240 1
        """.write(
            to: sparse.appendingPathComponent("images.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "1 0 0 1 128 128 128 0.5 1 0 2 0 3 0\n".write(
            to: sparse.appendingPathComponent("points3D.txt"),
            atomically: true,
            encoding: .utf8
        )

        try writeMinimalColmapBinaryModel(at: sparse, imageNames: (0..<3).map {
            String(format: "frame_%06d.jpg", $0)
        })
        let toolchain = try makeToolchain(root: temp, createMsplatFile: true)
        try persistGeometryArtifactFixture(
            metadata: &metadata,
            paths: paths,
            runtimeClosure: try ColmapRunner().captureRuntimeClosure(
                colmapPath: toolchain.colmap
            )
        )
        let geometry = try GeometryArtifactStore.load(
            from: paths.geometryManifestURL,
            projectPaths: paths,
            expectedInput: metadata.input
        )
        let identitySparse = try makeMsplatIdentitySparseFixture(
            from: sparse,
            under: paths.trainingURL,
            canonicalOrientation: geometry.canonicalOrientation
        )
        let datasetIdentity = try MsplatDatasetIdentity.compute(
            imageFiles: try FileManager.default.contentsOfDirectory(
                at: paths.framesSelectedURL,
                includingPropertiesForKeys: nil
            ),
            sparseDirectory: identitySparse
        )

        let memoryBudgetBytes = automaticTrainingMemoryBudgetBytes
        let receipt = try makeMsplatCheckpointFixture(
            at: paths.msplatCheckpointURL,
            iteration: 500,
            inputDigest: datasetIdentity.inputDigest,
            geometryDigest: datasetIdentity.geometryDigest,
            memoryBudgetBytes: memoryBudgetBytes
        )
        let artifact = TrainingArtifact(
            trainerVersion: "1.1.3 (git 106499b)",
            runtimeVersion: "native-metal-cli-v2",
            trainerBuildDigest: receipt.trainerBuildDigest,
            inputDigest: receipt.inputDigest,
            geometryDigest: receipt.geometryDigest,
            datasetDerivation: MsplatDatasetDerivationArtifact(
                sourceGeometryManifestSHA256: try GeometryArtifactStore.manifestDigest(
                    matching: geometry,
                    at: paths.geometryManifestURL
                ),
                sourceSelectedFramesDigest: geometry.selectedFramesDigest,
                preparationKind: .direct,
                maximumImageDimension: resolvedPlan.maximumImageDimension,
                toolchainVersion: geometry.provenance.toolchainVersion,
                colmapProvenance: geometry.provenance.solver,
                registeredImageNames: (0..<3).map {
                    String(format: "frame_%06d.jpg", $0)
                },
                datasetInputDigest: receipt.inputDigest,
                datasetGeometryDigest: receipt.geometryDigest
            ),
            detailProfile: .balanced,
            iterationLimit: 7_000,
            plateauWindow: 800,
            cameraOrderSeed: 42,
            completedIteration: receipt.iteration,
            checkpointPath: "Training/checkpoints/msplat",
            checkpointDigest: receipt.payloadSHA256,
            outputPath: nil,
            gaussianCount: receipt.gaussianCount,
            elapsedSeconds: nil,
            peakMemoryBytes: receipt.peakMemoryBytes,
            memoryBudgetBytes: receipt.memoryBudgetBytes,
            resourceAdmission: makeTestTrainingResourceAdmission(),
            rasterFallbackCount: receipt.rasterFallbackCount,
            rasterExactFallbackElapsedSeconds: receipt.rasterExactFallbackElapsedSeconds,
            rasterExactBufferGrowthCount: receipt.rasterExactBufferGrowthCount,
            rasterExactBufferBytesAdded: receipt.rasterExactBufferBytesAdded,
            rasterReplayElapsedSeconds: receipt.rasterReplayElapsedSeconds,
            rasterPeakExactIntersectionCapacity: receipt.rasterPeakExactIntersectionCapacity,
            droppedIntersectionCount: receipt.droppedIntersectionCount,
            completionStatus: .checkpointed
        )
        metadata.checkpoint = PipelineCheckpoint(
            stage: .trainSplat,
            inputReceiptDigest: try RuntimeInputSnapshotLease.receiptDigest(
                metadata: metadata
            ),
            details: .trainSplat(TrainSplatCheckpoint(
                progressStep: receipt.iteration,
                progressTotal: 7_000
            ))
        )
        try TrainingArtifactStore.persist(artifact, paths: paths)
        try ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: paths.metadataURL)

        let converterScript: () -> MockSubprocessRunner.Script = {
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    guard let outputPath = self.value(for: "--output_path", in: args) else { return }
                    let output = URL(fileURLWithPath: outputPath, isDirectory: true)
                    try? self.writeMinimalColmapBinaryModel(
                        at: output,
                        imageNames: (0..<3).map { String(format: "frame_%06d.jpg", $0) }
                    )
                }
            )
        }
        let failedRunner = MockSubprocessRunner(scripts: [
            converterScript(),
            .init(
                path: toolchain.msplat.path,
                argsPrefix: ["--dataset"],
                result: .init(
                    exitCode: 1,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: "simulated Metal failure"
                ),
                onRun: nil
            ),
        ])
        let failedPipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain),
            tooling: .init(
                runner: failedRunner,
                trainingResourceObserver: TestTrainingResourceObserver()
            )
        )
        await XCTAssertThrowsErrorAsync {
            try await failedPipeline.run(resumeFrom: .sfmMapping) { _ in }
        }

        let failedPipelineLog = try String(
            contentsOf: paths.pipelineLogURL,
            encoding: .utf8
        )
        XCTAssertFalse(
            failedPipelineLog.contains("Saved training state could not be validated"),
            failedPipelineLog
        )
        let failedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertNotNil(failedMetadata.state.lastError)
        XCTAssertNil(failedMetadata.checkpoint)
        XCTAssertEqual(
            try TrainingArtifactStore.load(
                from: paths.trainingManifestURL,
                projectPaths: paths
            ).completionStatus,
            .checkpointed
        )

        let outputProbe = temp.appendingPathComponent("balanced-retry-output-probe.ply")
        try TestFileBuilder.writeMinimalPly(at: outputProbe, vertexCount: 1_400)
        let outputBytes = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: outputProbe.path)[.size] as? NSNumber)?.int64Value
        )
        try FileManager.default.removeItem(at: outputProbe)
        let resumedEvents = """
        {"camera_count":8,"checkpoint_schema":3,"event":"started","geometry_digest":"\(receipt.geometryDigest)","initial_gaussian_count":\(receipt.gaussianCount),"input_digest":"\(receipt.inputDigest)","iteration":500,"iteration_limit":7000,"memory_budget_bytes":\(memoryBudgetBytes),"payload_schema":2,"plateau_window":800,"profile":"balanced","raster_exact_buffer_bytes_added":\(receipt.rasterExactBufferBytesAdded),"raster_exact_buffer_growth_count":\(receipt.rasterExactBufferGrowthCount),"raster_exact_fallback_elapsed_seconds":\(receipt.rasterExactFallbackElapsedSeconds),"raster_fallback_count":\(receipt.rasterFallbackCount),"raster_peak_exact_intersection_capacity":\(receipt.rasterPeakExactIntersectionCapacity),"raster_replay_elapsed_seconds":\(receipt.rasterReplayElapsedSeconds),"resumed":true,"schema_version":2,"seed":42,"sequence":1,"trainer_build_digest":"\(receipt.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
        {"checkpoint_generation":"\(receipt.generation)","checkpoint_payload_bytes":\(receipt.payloadBytes),"checkpoint_payload_sha256":"\(receipt.payloadSHA256)","dropped_intersection_count":0,"event":"checkpoint_loaded","gaussian_count":\(receipt.gaussianCount),"geometry_digest":"\(receipt.geometryDigest)","input_digest":"\(receipt.inputDigest)","iteration":500,"memory_budget_bytes":\(memoryBudgetBytes),"peak_memory_bytes":\(receipt.peakMemoryBytes),"profile":"balanced","raster_exact_buffer_bytes_added":\(receipt.rasterExactBufferBytesAdded),"raster_exact_buffer_growth_count":\(receipt.rasterExactBufferGrowthCount),"raster_exact_fallback_elapsed_seconds":\(receipt.rasterExactFallbackElapsedSeconds),"raster_fallback_count":\(receipt.rasterFallbackCount),"raster_peak_exact_intersection_capacity":\(receipt.rasterPeakExactIntersectionCapacity),"raster_replay_elapsed_seconds":\(receipt.rasterReplayElapsedSeconds),"schema_version":2,"seed":42,"sequence":2,"trainer_build_digest":"\(receipt.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
        {"elapsed_seconds":4,"eta_seconds":0,"event":"progress","gaussian_count":1400,"iteration":7000,"iteration_limit":7000,"iterations_per_second":1600,"schema_version":2,"sequence":3}
        {"dropped_intersection_count":0,"elapsed_seconds":4,"event":"completed","gaussian_count":1400,"geometry_digest":"\(receipt.geometryDigest)","input_digest":"\(receipt.inputDigest)","iteration":7000,"iteration_limit":7000,"memory_budget_bytes":\(memoryBudgetBytes),"output_bytes":\(outputBytes),"peak_memory_bytes":805306368,"plateau_window":800,"profile":"balanced","raster_exact_buffer_bytes_added":\(receipt.rasterExactBufferBytesAdded),"raster_exact_buffer_growth_count":\(receipt.rasterExactBufferGrowthCount),"raster_exact_fallback_elapsed_seconds":\(receipt.rasterExactFallbackElapsedSeconds),"raster_fallback_count":\(receipt.rasterFallbackCount),"raster_peak_exact_intersection_capacity":\(receipt.rasterPeakExactIntersectionCapacity),"raster_replay_elapsed_seconds":\(receipt.rasterReplayElapsedSeconds),"scene_center":[0,0,0],"scene_radius":2.5,"schema_version":2,"seed":42,"sequence":4,"stop_reason":"iteration_limit","trainer_build_digest":"\(receipt.trainerBuildDigest)","version":"1.1.3 (git 106499b)"}
        """ + "\n"
        let retryRunner = MockSubprocessRunner(scripts: [
            converterScript(),
            .init(
                path: toolchain.msplat.path,
                argsPrefix: ["--dataset"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: resumedEvents, stderr: ""),
                onRun: { args in
                    guard let outputPath = self.value(for: "--output", in: args) else { return }
                    try? TestFileBuilder.writeMinimalPly(
                        at: URL(fileURLWithPath: outputPath),
                        vertexCount: 1_400
                    )
                }
            )
        ])
        let retryPipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain),
            tooling: .init(
                runner: retryRunner,
                trainingResourceObserver: TestTrainingResourceObserver()
            )
        )

        try await retryPipeline.run(resumeFrom: .sfmMapping) { _ in }

        let retryCall = try XCTUnwrap(retryRunner.calls.first(where: { $0.0 == toolchain.msplat.path }))
        XCTAssertEqual(value(for: "--resume", in: retryCall.1), paths.msplatCheckpointURL.path)
        XCTAssertEqual(
            try TrainingArtifactStore.load(
                from: paths.trainingManifestURL,
                projectPaths: paths
            ).peakMemoryBytes,
            805_306_368
        )
    }

    func testPipelineDa3CancellationDoesNotFallbackBetweenBackends() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Da3Cancel.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<10 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(
            title: "Da3Cancel",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .fast,
                cameraGrouping: .sameCameraAndLens
            )
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(metadata, paths: paths)

        let toolchain = try makeToolchain(root: temp, createDa3Files: true)
        let runner = CancellationOnSfmRunner(cancelPath: toolchain.da3.sfmTool.path)

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, candidateRoute: .da3, skipTraining: true),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync({
            try await pipeline.run { _ in }
        }, errorHandler: { error in
            XCTAssertTrue(error is CancellationError)
        })

        let callPaths = runner.calls.map { $0.0 }
        XCTAssertEqual(callPaths.filter { $0 == toolchain.da3.sfmTool.path }.count, 1)
        let da3Args = runner.calls.first(where: { $0.0 == toolchain.da3.sfmTool.path })?.1 ?? []
        XCTAssertFalse(da3Args.contains("--mode"))
        XCTAssertFalse(callPaths.contains(toolchain.colmap.path))
        let interruptedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertNotNil(interruptedMetadata.lastRunStartedAt, "Cancellation should preserve lastRunStartedAt for crash/interruption detection.")
    }

    func testConstrainedDa3CandidateRunsAndPublishesOnlyThePlannedSmallModel() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<3 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       requestedRunOptions: RequestedRunOptions(
                                        capturePath: .orbit,
                                        detailProfile: .balanced,
                                        cameraGrouping: .sameCameraAndLens
                                       ))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(metadata, paths: paths)

        let toolchain = try makeToolchain(root: temp, createDa3Files: true)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.da3.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                do {
                    try self.writeDa3RunArtifacts(for: args)
                } catch {
                    XCTFail("Failed to write DA3 test artifacts: \(error)")
                }
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                XCTAssertEqual(self.value(for: "--ImageReader.single_camera", in: args), "1")
                XCTAssertEqual(self.value(for: "--ImageReader.camera_model", in: args), "SIMPLE_RADIAL")
                try? self.writeFeatureDatabase(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["matches_importer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                try? self.writeVerifiedPairResults(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["point_triangulator"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let output = self.value(for: "--output_path", in: args) else { return }
                try? self.writeDa3SparseModel(
                    at: URL(fileURLWithPath: output),
                    imageNames: self.selectedImageNames(in: paths),
                    pointCount: 20
                )
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["bundle_adjuster"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                XCTAssertEqual(
                    self.value(for: "--BundleAdjustment.refine_extra_params", in: args),
                    "1"
                )
                guard let output = self.value(for: "--output_path", in: args) else { return }
                try? self.writeDa3SparseModel(
                    at: URL(fileURLWithPath: output),
                    imageNames: self.selectedImageNames(in: paths),
                    pointCount: 20
                )
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 3 / 3\nPoints: 16000\nObservations: 48000\nMean track length: 3.0\nMean reprojection error: 0.8\n", stderr: ""), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .da3,
                skipTraining: true,
                hardwareProfile: HardwareProfile(
                    memoryGB: 16,
                    cpuCount: 16,
                    gpuWorkingSetGB: 12
                )
            ),
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        let callPaths = runner.calls.map { $0.0 }
        XCTAssertTrue(callPaths.contains(toolchain.da3.sfmTool.path))
        XCTAssertTrue(callPaths.contains(toolchain.colmap.path))
        let da3Args = try XCTUnwrap(runner.calls.first(where: { $0.0 == toolchain.da3.sfmTool.path })?.1)
        XCTAssertFalse(da3Args.contains("--mode"))
        XCTAssertEqual(value(for: "--model-subdir", in: da3Args), "DA3-SMALL")
        XCTAssertFalse(da3Args.contains("--fallback-model-subdir"))
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "model_analyzer" }))
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "point_triangulator" }))
        let finished = try ProjectMetadataStore.load(from: paths.metadataURL)
        let geometry = try GeometryArtifactStore.load(
            from: paths.geometryManifestURL,
            projectPaths: paths,
            expectedInput: finished.input
        )
        XCTAssertEqual(
            geometry.modelVersion,
            "DA3-SMALL@89abcdef0123456789abcdef0123456789abcdef"
        )
        XCTAssertEqual(geometry.provenance.runtime?.identifier, "da3_mps")
        XCTAssertEqual(geometry.provenance.model?.identifier, "DA3-SMALL")
        XCTAssertEqual(
            geometry.provenance.model?.payloadSHA256,
            try GeometryArtifactStore.sha256(
                of: toolchain.da3.smallModelBundle.appendingPathComponent("model.safetensors")
            )
        )
    }

    func testUnderSupportedDa3ViewsStopStrictCandidateRun() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("ResidualFallback.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<3 {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(index)
            )
        }

        let metadata = ProjectMetadata(
            title: "Residual fallback",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .fast,
                cameraGrouping: .sameCameraAndLens
            )
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(metadata, paths: paths)
        let toolchain = try makeToolchain(root: temp, createDa3Files: true)
        let acceptedReport = "Registered images: 3 / 3\nPoints: 16000\nObservations: 48000\nMean track length: 3.0\nMean reprojection error: 0.8\n"
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.da3.sfmTool.path,
                argsPrefix: ["--images"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    do {
                        try self.writeDa3RunArtifacts(for: args)
                    } catch {
                        XCTFail("Failed to prepare DA3 seed artifacts: \(error)")
                    }
                }
            ),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                try? self.writeFeatureDatabase(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["matches_importer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                try? self.writeVerifiedPairResults(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["point_triangulator"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let output = self.value(for: "--output_path", in: args) else { return }
                do {
                    let modelURL = URL(fileURLWithPath: output)
                    try self.writeDa3SparseModel(
                        at: modelURL,
                        imageNames: self.selectedImageNames(in: paths),
                        pointCount: 4
                    )
                } catch {
                    XCTFail("Failed to prepare under-supported triangulated model: \(error)")
                }
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["bundle_adjuster"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let output = self.value(for: "--output_path", in: args) else { return }
                do {
                    let modelURL = URL(fileURLWithPath: output)
                    try self.writeDa3SparseModel(
                        at: modelURL,
                        imageNames: self.selectedImageNames(in: paths),
                        pointCount: 4
                    )
                } catch {
                    XCTFail("Failed to prepare under-supported adjusted model: \(error)")
                }
            }),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: acceptedReport, stderr: ""),
                onRun: nil
            ),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["mapper"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    guard let output = self.value(for: "--output_path", in: args) else { return }
                    try? self.writeDa3SparseModel(
                        at: URL(fileURLWithPath: output).appendingPathComponent("0", isDirectory: true),
                        imageNames: [
                            "frame_000000.jpg",
                            "frame_000001.jpg",
                            "frame_000002.jpg",
                        ],
                        pointCount: 4
                    )
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: acceptedReport, stderr: ""),
                onRun: nil
            ),
        ])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .da3,
                skipTraining: true
            ),
            tooling: .init(runner: runner)
        )
        let events = PipelineEventSink()

        await XCTAssertThrowsErrorAsync({
            try await pipeline.run { event in
                events.append(event)
            }
        })

        XCTAssertFalse(runner.calls.contains { $0.1.first == "mapper" })
        XCTAssertNil(events.stageLog(containing: "Falling back to COLMAP"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.geometryManifestURL.path))
    }

    func testPipelineOversizedDa3SeedRunsBoundedRefinementBeforeAcceptance() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Da3AlignedSeed.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<29 {
            try writeRetrievalTestImage(
                url: sourcePhotos.appendingPathComponent(String(format: "img_%03d.jpg", index)),
                index: index
            )
        }

        let metadata = ProjectMetadata(
            title: "Da3AlignedSeed",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .fast,
                cameraGrouping: .sameCameraAndLens,
                inputOrdering: .continuous,
                photoSelection: .useAllValidPhotos
            )
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(metadata, paths: paths)

        let toolchain = try makeToolchain(root: temp, createDa3Files: true)
        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.da3.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                try? self.writeDa3RunArtifacts(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                try? self.writeFeatureDatabase(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["matches_importer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let path = self.value(for: "--match_list_path", in: args),
                      let pairs = try? String(contentsOfFile: path, encoding: .utf8) else {
                    return XCTFail("DA3 refinement pair list was not readable")
                }
                XCTAssertTrue(pairs.contains("frame_000000.jpg frame_000028.jpg"))
                try? self.writeVerifiedPairResults(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["point_triangulator"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let output = self.value(for: "--output_path", in: args) else { return }
                try? self.writeDa3SparseModel(
                    at: URL(fileURLWithPath: output),
                    imageNames: self.selectedImageNames(in: paths),
                    pointCount: 20
                )
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["bundle_adjuster"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let output = self.value(for: "--output_path", in: args) else { return }
                try? self.writeDa3SparseModel(
                    at: URL(fileURLWithPath: output),
                    imageNames: self.selectedImageNames(in: paths),
                    pointCount: 20
                )
            }),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: 29 / 29\nPoints: 16000\nObservations: 32000\nMean track length: 2.0\nMean reprojection error: 0.8\n",
                    stderr: ""
                ),
                onRun: nil
            )
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, candidateRoute: .da3, skipTraining: true),
            tooling: .init(runner: runner)
        )
        let events = PipelineEventSink()
        try await pipeline.run { events.append($0) }

        let da3Args = try XCTUnwrap(runner.calls.first(where: { $0.0 == toolchain.da3.sfmTool.path })?.1)
        XCTAssertFalse(da3Args.contains("--mode"))
        XCTAssertEqual(value(for: "--input-ordering", in: da3Args), "continuous")
        let commands = runner.calls.filter { $0.0 == toolchain.colmap.path }.compactMap { $0.1.first }
        XCTAssertEqual(commands, ["feature_extractor", "matches_importer", "point_triangulator", "bundle_adjuster", "model_analyzer"])
        XCTAssertFalse(commands.contains("mapper"))
        XCTAssertNotNil(events.stageLog(containing: "DA3 refinement pair plan"))

        let finished = try ProjectMetadataStore.load(from: paths.metadataURL)
        let geometry = try GeometryArtifactStore.load(
            from: paths.geometryManifestURL,
            projectPaths: paths,
            expectedInput: finished.input
        )
        XCTAssertTrue(geometry.solverVersion.hasPrefix("da3-refined;"))
        XCTAssertEqual(geometry.medianPixelResidual, 0)
        XCTAssertEqual(geometry.pairGraph.status, .measured)
        XCTAssertEqual(
            geometry.pairGraph.measurement?.scheduledPairCount,
            406
        )
        XCTAssertEqual(
            geometry.pairGraph.measurement?.matcherAttempts.map(\.matcher),
            [.faiss]
        )
        XCTAssertEqual(geometry.mapping.modelCount, 1)
        XCTAssertEqual(geometry.mapping.largestModelRegisteredViewCount, 29)
        XCTAssertEqual(geometry.mapping.secondLargestModelRegisteredViewCount, 0)
        XCTAssertEqual(geometry.mapping.unionRegisteredViewCount, 29)
        XCTAssertEqual(geometry.mapping.attemptCount, 1)
        XCTAssertEqual(geometry.mapping.acceptedRefinementKind, .seededBundleAdjustment)
        XCTAssertEqual(geometry.mapping.acceptedRefinementInvocationCount, 1)
        XCTAssertNil(geometry.mapping.fallbackReason)
    }

    func testDa3CancellationBeforeTriangulationDoesNotLaunchColmap() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent(
            "Da3CancelledBeforeTriangulation.easysplatproj",
            isDirectory: true
        )
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<3 {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(index)
            )
        }
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(
            ProjectMetadata(
                title: "DA3 cancellation",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    capturePath: .orbit,
                    detailProfile: .fast,
                    cameraGrouping: .sameCameraAndLens
                )
            ),
            paths: paths
        )

        let toolchain = try makeToolchain(root: temp, createDa3Files: true)
        let seedRunner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.da3.sfmTool.path,
                argsPrefix: ["--images"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in try? self.writeDa3RunArtifacts(for: args) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in try? self.writeFeatureDatabase(for: args) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in try? self.writeVerifiedPairResults(for: args) }
            ),
        ])
        let seedPipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .da3,
                skipTraining: true,
                stopAfterStage: .sfmMatching
            ),
            tooling: .init(runner: seedRunner)
        )
        try await seedPipeline.run { _ in }

        let resumeRunner = MockSubprocessRunner(scripts: [])
        let resumedPipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .da3,
                skipTraining: true
            ),
            tooling: .init(
                runner: resumeRunner,
                checkCancellation: { throw CancellationError() }
            )
        )
        let events = PipelineEventSink()

        await XCTAssertThrowsErrorAsync({
            try await resumedPipeline.run(resumeFrom: .sfmMatching) { events.append($0) }
        }, errorHandler: { error in
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        })

        XCTAssertTrue(events.didStart(.sfmMapping))
        XCTAssertTrue(resumeRunner.calls.isEmpty)
    }

    func testDa3RefinementFaissCrashRetriesBoundedExactWithoutReextractingFeatures() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Da3FaissRecovery.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<20 {
            try writeRetrievalTestImage(
                url: sourcePhotos.appendingPathComponent(String(format: "img_%03d.jpg", index)),
                index: index
            )
        }

        let metadata = ProjectMetadata(
            title: "DA3 FAISS recovery",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .fast,
                cameraGrouping: .sameCameraAndLens,
                inputOrdering: .continuous,
                photoSelection: .useAllValidPhotos
            )
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(metadata, paths: paths)

        let toolchain = try makeToolchain(root: temp, createDa3Files: true)
        let runner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.da3.sfmTool.path,
                argsPrefix: ["--images"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in try? self.writeDa3RunArtifacts(for: args) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    do {
                        try self.writeFeatureDatabase(for: args)
                    } catch {
                        XCTFail("Could not create COLMAP database fixture: \(error)")
                    }
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(
                    exitCode: SIGSEGV,
                    terminationReason: .uncaughtSignal,
                    stdout: "",
                    stderr: "segmentation fault"
                ),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: args), "0")
                    XCTAssertEqual(try? self.pairListLines(for: args).count, 190)
                    try? self.writePartialMatchRows(at: paths.colmapDatabaseURL)
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: args), "1")
                    XCTAssertEqual(try? self.pairListLines(for: args).count, 190)
                    XCTAssertEqual(try? self.databaseRowCount("descriptors", at: paths.colmapDatabaseURL), 20)
                    XCTAssertEqual(try? self.databaseRowCount("keypoints", at: paths.colmapDatabaseURL), 20)
                    XCTAssertEqual(try? self.databaseRowCount("matches", at: paths.colmapDatabaseURL), 0)
                    XCTAssertEqual(try? self.databaseRowCount("two_view_geometries", at: paths.colmapDatabaseURL), 0)
                    try? self.writeVerifiedPairResults(for: args)
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["point_triangulator"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    guard let output = self.value(for: "--output_path", in: args) else { return }
                    try? self.writeDa3SparseModel(
                        at: URL(fileURLWithPath: output),
                        imageNames: self.selectedImageNames(in: paths),
                        pointCount: 20
                    )
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["bundle_adjuster"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    guard let output = self.value(for: "--output_path", in: args) else { return }
                    try? self.writeDa3SparseModel(
                        at: URL(fileURLWithPath: output),
                        imageNames: self.selectedImageNames(in: paths),
                        pointCount: 20
                    )
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: 20 / 20\nPoints: 16000\nObservations: 32000\nMean track length: 2.0\nMean reprojection error: 0.8\n",
                    stderr: ""
                ),
                onRun: nil
            ),
        ])
        let events = PipelineEventSink()
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, candidateRoute: .da3, skipTraining: true),
            tooling: .init(runner: runner)
        )

        do {
            try await pipeline.run { events.append($0) }
        } catch {
            XCTFail("Pipeline failed after calls \(runner.calls): \(error)")
            return
        }

        let commands = runner.calls.filter { $0.0 == toolchain.colmap.path }.compactMap { $0.1.first }
        XCTAssertEqual(
            commands,
            ["feature_extractor", "matches_importer", "matches_importer", "point_triangulator", "bundle_adjuster", "model_analyzer"]
        )
        XCTAssertNotNil(events.stageLog(containing: "preserving features and retrying with exact matching"))
        let geometry = try GeometryArtifactStore.load(
            from: paths.geometryManifestURL,
            projectPaths: paths
        )
        XCTAssertEqual(geometry.mapping.attemptCount, 1)
        XCTAssertEqual(geometry.mapping.acceptedRefinementKind, .seededBundleAdjustment)
        XCTAssertEqual(geometry.mapping.acceptedRefinementInvocationCount, 1)
        XCTAssertEqual(geometry.mapping.fallbackReason, "exact descriptor matching")
        XCTAssertEqual(geometry.pairGraph.status, .measured)
        let measurement = try XCTUnwrap(geometry.pairGraph.measurement)
        XCTAssertEqual(measurement.matcherAttempts.map(\.matcher), [.faiss, .exact])
        XCTAssertEqual(measurement.matcherAttempts.map(\.outcome), [.failed, .completed])
        XCTAssertEqual(measurement.matcherAttempts[0].attemptedPairCount, 1)
        XCTAssertEqual(measurement.matcherAttempts[0].rawMatchedPairCount, 1)
        XCTAssertEqual(measurement.matcherAttempts[0].spatiallyVerifiedPairCount, 0)
        XCTAssertEqual(
            measurement.matchingDurationSeconds,
            measurement.matcherAttempts.reduce(0) {
                $0 + $1.durationSeconds
            },
            accuracy: 1e-12
        )
        let finishedMetadata = try ProjectMetadataStore.load(
            from: paths.metadataURL
        )
        let resolvedPlan = try XCTUnwrap(finishedMetadata.resolvedRunPlan)
        let selectedNames = selectedImageNames(in: paths)
        let manifest = try Da3CoverageManifest.load(
            from: paths.da3CoverageManifestURL
        )
        let expectedPairPlan = try ColmapPairEstimator.validatedDa3RefinementPairPlan(
            manifest: manifest,
            imageNames: selectedNames,
            resolvedPlan: resolvedPlan
        )
        let pairEvidence = try PairGraphEvidenceStore.loadVerifiedDa3Refinement(
            from: paths.pairGraphEvidenceURL,
            expectedImageNames: selectedNames,
            expectedPlanBinding: PairGraphPlanBinding(resolvedPlan),
            expectedPairPlan: expectedPairPlan,
            databaseURL: paths.colmapDatabaseURL,
            projectPaths: paths
        )
        let workerExecution = try GeometryWorkerExecutionArtifactStore.load(
            from: paths.workerExecutionURL,
            expectedBudget: resolvedPlan.geometryWorkerBudget,
            projectPaths: paths
        )
        XCTAssertNoThrow(try PairGraphEvidenceStore.validateDa3WorkerExecution(
            pairEvidence,
            expectedPlanBinding: PairGraphPlanBinding(resolvedPlan),
            expectedPairPlan: expectedPairPlan,
            workerExecution: workerExecution
        ))
    }

    func testFailedDa3ExactAttemptRestartsFreshFaissAcrossRelaunch() async throws {
        let temp = makeTempRoot()
        let fixture = try makeDa3RecoveryProject(
            in: temp,
            name: "FailedDa3ExactIsTerminal"
        )
        let firstRunner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.toolchain.da3.sfmTool.path,
                argsPrefix: ["--images"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: ""
                ),
                onRun: { args in try self.writeDa3RunArtifacts(for: args) }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: ""
                ),
                onRun: { args in try self.writeFeatureDatabase(for: args) }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(
                    exitCode: SIGSEGV,
                    terminationReason: .uncaughtSignal,
                    stdout: "",
                    stderr: "segmentation fault"
                )
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(
                    exitCode: 1,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: "exact matcher failed"
                )
            ),
        ])
        let firstPipeline = PipelineRunner(
            projectURL: fixture.projectURL,
            config: makePipelineConfig(
                toolchain: fixture.toolchain,
                candidateRoute: .da3,
                skipTraining: true
            ),
            tooling: .init(runner: firstRunner)
        )
        await XCTAssertThrowsErrorAsync({
            try await firstPipeline.run { _ in }
        })

        let failedMetadata = try ProjectMetadataStore.load(
            from: fixture.paths.metadataURL
        )
        XCTAssertEqual(failedMetadata.state.stage, .sfmMatching)
        XCTAssertNil(failedMetadata.geometryRecovery)
        let failedWorkerExecution = try GeometryWorkerExecutionArtifactStore.load(
            from: GeometryWorkerExecutionArtifactStore.canonicalURL(
                for: fixture.paths
            ),
            projectPaths: fixture.paths
        )
        XCTAssertEqual(
            failedWorkerExecution.matchingInvocations.map(\.succeeded),
            [false, false]
        )

        let resumedRunner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: ""
                ),
                onRun: { arguments in
                    XCTAssertEqual(
                        self.value(
                            for: "--SiftMatching.cpu_brute_force_matcher",
                            in: arguments
                        ),
                        "0"
                    )
                    try self.writeVerifiedPairResults(for: arguments)
                }
            ),
        ])
        let resumedPipeline = PipelineRunner(
            projectURL: fixture.projectURL,
            config: makePipelineConfig(
                toolchain: fixture.toolchain,
                candidateRoute: .da3,
                skipTraining: true,
                stopAfterStage: .sfmMatching
            ),
            tooling: .init(runner: resumedRunner)
        )
        try await resumedPipeline.run(resumeFrom: .sfmFeatures) { _ in }

        XCTAssertEqual(
            resumedRunner.calls.filter { $0.1.first == "matches_importer" }.count,
            1
        )
        let resumedWorkerExecution = try GeometryWorkerExecutionArtifactStore.load(
            from: GeometryWorkerExecutionArtifactStore.canonicalURL(
                for: fixture.paths
            ),
            projectPaths: fixture.paths
        )
        XCTAssertEqual(resumedWorkerExecution.matchingInvocations.count, 1)
        XCTAssertEqual(
            resumedWorkerExecution.matchingInvocations.first?
                .pairExecution?.attemptOrdinal,
            1
        )
        XCTAssertEqual(
            resumedWorkerExecution.matchingInvocations.first?
                .pairExecution?.descriptorMatcher,
            .faiss
        )
    }

    func testInterruptedDa3ExactRecoveryRestartsFaissWithoutRepeatingFeatures() async throws {
        let temp = makeTempRoot()
        let fixture = try makeDa3RecoveryProject(
            in: temp,
            name: "InterruptedDa3ExactRecovery"
        )
        let firstRunner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.toolchain.da3.sfmTool.path,
                argsPrefix: ["--images"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: ""
                ),
                onRun: { args in try self.writeDa3RunArtifacts(for: args) }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: ""
                ),
                onRun: { args in try self.writeFeatureDatabase(for: args) }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(
                    exitCode: SIGSEGV,
                    terminationReason: .uncaughtSignal,
                    stdout: "",
                    stderr: "segmentation fault"
                )
            ),
        ])
        let firstPipeline = PipelineRunner(
            projectURL: fixture.projectURL,
            config: makePipelineConfig(
                toolchain: fixture.toolchain,
                candidateRoute: .da3,
                skipTraining: true
            ),
            tooling: .init(runner: firstRunner)
        )
        let interruptedTask = Task {
            try await firstPipeline.run { event in
                guard case let .stageLog(stage, line, _) = event,
                      stage == .sfmMatching,
                      line.contains("preserving features and retrying") else {
                    return
                }
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        await XCTAssertThrowsErrorAsync({
            try await interruptedTask.value
        }, errorHandler: { error in
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        })
        XCTAssertEqual(
            firstRunner.calls.filter {
                $0.0 == fixture.toolchain.colmap.path
                    && $0.1.first == "matches_importer"
            }.count,
            1
        )

        let interruptedMetadata = try ProjectMetadataStore.load(
            from: fixture.paths.metadataURL
        )
        XCTAssertNil(interruptedMetadata.geometryRecovery)
        let interruptedWorkerExecution = try GeometryWorkerExecutionArtifactStore.load(
            from: GeometryWorkerExecutionArtifactStore.canonicalURL(
                for: fixture.paths
            ),
            projectPaths: fixture.paths
        )
        XCTAssertEqual(
            interruptedWorkerExecution.matchingInvocations.map(\.succeeded),
            [false]
        )

        let resumedRunner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: ""
                ),
                onRun: { arguments in
                    XCTAssertEqual(
                        self.value(
                            for: "--SiftMatching.cpu_brute_force_matcher",
                            in: arguments
                        ),
                        "0"
                    )
                    try self.writeVerifiedPairResults(for: arguments)
                }
            ),
        ])
        let resumedPipeline = PipelineRunner(
            projectURL: fixture.projectURL,
            config: makePipelineConfig(
                toolchain: fixture.toolchain,
                candidateRoute: .da3,
                skipTraining: true,
                stopAfterStage: .sfmMatching
            ),
            tooling: .init(runner: resumedRunner)
        )
        try await resumedPipeline.run(resumeFrom: .sfmFeatures) { _ in }

        let resumedCommands = resumedRunner.calls
            .filter { $0.0 == fixture.toolchain.colmap.path }
            .compactMap { $0.1.first }
        XCTAssertEqual(resumedCommands, ["matches_importer"])
    }

    func testDa3ResumeRestartsFaissWhenRowsWereClearedAfterRecordedExactSuccess() async throws {
        let temp = makeTempRoot()
        let fixture = try makeDa3RecoveryProject(
            in: temp,
            name: "Da3ExactReceiptWithoutRows"
        )
        let firstRunner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.toolchain.da3.sfmTool.path,
                argsPrefix: ["--images"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: ""
                ),
                onRun: { args in try self.writeDa3RunArtifacts(for: args) }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: ""
                ),
                onRun: { args in try self.writeFeatureDatabase(for: args) }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(
                    exitCode: SIGSEGV,
                    terminationReason: .uncaughtSignal,
                    stdout: "",
                    stderr: "segmentation fault"
                )
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: ""
                ),
                onRun: { args in try self.writeVerifiedPairResults(for: args) }
            ),
        ])
        let firstPipeline = PipelineRunner(
            projectURL: fixture.projectURL,
            config: makePipelineConfig(
                toolchain: fixture.toolchain,
                candidateRoute: .da3,
                skipTraining: true,
                stopAfterStage: .sfmMatching
            ),
            tooling: .init(runner: firstRunner)
        )
        try await firstPipeline.run { _ in }

        let recorded = try GeometryWorkerExecutionArtifactStore.load(
            from: GeometryWorkerExecutionArtifactStore.canonicalURL(
                for: fixture.paths
            ),
            projectPaths: fixture.paths
        )
        XCTAssertEqual(recorded.matchingInvocations.map(\.succeeded), [false, true])
        XCTAssertGreaterThan(
            try databaseRowCount(
                "two_view_geometries",
                at: fixture.paths.colmapDatabaseURL
            ),
            0
        )

        try ColmapDatabaseMatchStore.clearMatchingResults(
            at: fixture.paths.colmapDatabaseURL
        )
        try markMatchingAsInterrupted(paths: fixture.paths)
        let resumedRunner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: ""
                ),
                onRun: { arguments in
                    XCTAssertEqual(
                        self.value(
                            for: "--SiftMatching.cpu_brute_force_matcher",
                            in: arguments
                        ),
                        "0"
                    )
                    XCTAssertEqual(
                        try self.databaseRowCount(
                            "two_view_geometries",
                            at: fixture.paths.colmapDatabaseURL
                        ),
                        0
                    )
                    try self.writeVerifiedPairResults(for: arguments)
                }
            ),
        ])
        let resumedPipeline = PipelineRunner(
            projectURL: fixture.projectURL,
            config: makePipelineConfig(
                toolchain: fixture.toolchain,
                candidateRoute: .da3,
                skipTraining: true,
                stopAfterStage: .sfmMatching
            ),
            tooling: .init(runner: resumedRunner)
        )
        try await resumedPipeline.run(resumeFrom: .sfmFeatures) { _ in }

        XCTAssertEqual(
            resumedRunner.calls.filter {
                $0.0 == fixture.toolchain.colmap.path
                    && $0.1.first == "matches_importer"
            }.count,
            1
        )
        XCTAssertGreaterThan(
            try databaseRowCount(
                "two_view_geometries",
                at: fixture.paths.colmapDatabaseURL
            ),
            0
        )
    }

    func testDa3CompleteEvidenceSurvivesCrashBeforeMatchingCheckpoint() async throws {
        let temp = makeTempRoot()
        let fixture = try makeDa3RecoveryProject(
            in: temp,
            name: "Da3EvidenceBeforeCheckpoint"
        )
        let firstRunner = MockSubprocessRunner(scripts: [
            .init(
                path: fixture.toolchain.da3.sfmTool.path,
                argsPrefix: ["--images"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: ""
                ),
                onRun: { args in try self.writeDa3RunArtifacts(for: args) }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: ""
                ),
                onRun: { args in try self.writeFeatureDatabase(for: args) }
            ),
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: ""
                ),
                onRun: { args in try self.writeVerifiedPairResults(for: args) }
            ),
        ])
        let firstPipeline = PipelineRunner(
            projectURL: fixture.projectURL,
            config: makePipelineConfig(
                toolchain: fixture.toolchain,
                candidateRoute: .da3,
                skipTraining: true,
                stopAfterStage: .sfmMatching
            ),
            tooling: .init(runner: firstRunner)
        )
        try await firstPipeline.run { _ in }

        try markMatchingAsInterrupted(paths: fixture.paths)
        let resumedRunner = MockSubprocessRunner(scripts: [])
        let resumedPipeline = PipelineRunner(
            projectURL: fixture.projectURL,
            config: makePipelineConfig(
                toolchain: fixture.toolchain,
                candidateRoute: .da3,
                skipTraining: true,
                stopAfterStage: .sfmMatching
            ),
            tooling: .init(runner: resumedRunner)
        )

        try await resumedPipeline.run(resumeFrom: .sfmFeatures) { _ in }

        XCTAssertTrue(resumedRunner.calls.isEmpty)
        XCTAssertGreaterThan(
            try databaseRowCount(
                "two_view_geometries",
                at: fixture.paths.colmapDatabaseURL
            ),
            0
        )
    }

    func testInterruptedDa3MatchingClearsPartialExactRowsBeforeFaissResume() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent(
            "InterruptedDa3Matching.easysplatproj",
            isDirectory: true
        )
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<29 {
            try writeRetrievalTestImage(
                url: sourcePhotos.appendingPathComponent(String(format: "img_%03d.jpg", index)),
                index: index
            )
        }

        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(
            ProjectMetadata(
                title: "Interrupted DA3 matching",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    capturePath: .orbit,
                    detailProfile: .fast,
                    cameraGrouping: .sameCameraAndLens,
                    inputOrdering: .continuous,
                    photoSelection: .useAllValidPhotos
                )
            ),
            paths: paths
        )

        let toolchain = try makeToolchain(root: temp, createDa3Files: true)
        let seedRunner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.da3.sfmTool.path,
                argsPrefix: ["--images"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in try? self.writeDa3RunArtifacts(for: args) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in try self.writeFeatureDatabase(for: args) }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(
                        self.value(
                            for: "--SiftMatching.cpu_brute_force_matcher",
                            in: args
                        ),
                        "0"
                    )
                    try self.writePartialMatchRows(at: paths.colmapDatabaseURL)
                    throw CancellationError()
                }
            ),
        ])
        let seedPipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .da3,
                skipTraining: true
            ),
            tooling: .init(runner: seedRunner)
        )
        do {
            try await seedPipeline.run { _ in }
            XCTFail("Expected DA3 matching to be interrupted")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(try databaseRowCount("matches", at: paths.colmapDatabaseURL), 1)
        XCTAssertEqual(
            try databaseRowCount("two_view_geometries", at: paths.colmapDatabaseURL),
            1
        )

        let resumeRunner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: nil
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(
                        self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: args),
                        "0"
                    )
                    XCTAssertEqual(
                        try? self.databaseRowCount("matches", at: paths.colmapDatabaseURL),
                        0
                    )
                    XCTAssertEqual(
                        try? self.databaseRowCount(
                            "two_view_geometries",
                            at: paths.colmapDatabaseURL
                        ),
                        0
                    )
                    try? self.writeVerifiedPairResults(for: args)
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["point_triangulator"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    guard let output = self.value(for: "--output_path", in: args) else { return }
                    try? self.writeDa3SparseModel(
                        at: URL(fileURLWithPath: output),
                        imageNames: self.selectedImageNames(in: paths),
                        pointCount: 20
                    )
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["bundle_adjuster"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    guard let output = self.value(for: "--output_path", in: args) else { return }
                    try? self.writeDa3SparseModel(
                        at: URL(fileURLWithPath: output),
                        imageNames: self.selectedImageNames(in: paths),
                        pointCount: 20
                    )
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: 29 / 29\nPoints: 16000\nObservations: 32000\nMean track length: 2.0\nMean reprojection error: 0.8\n",
                    stderr: ""
                ),
                onRun: nil
            ),
        ])
        let events = PipelineEventSink()
        let resumedPipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .da3,
                skipTraining: true
            ),
            tooling: .init(runner: resumeRunner)
        )

        try await resumedPipeline.run(resumeFrom: .sfmFeatures) { events.append($0) }

        XCTAssertNotNil(events.stageLog(containing: "Discarded partial image matches"))
        XCTAssertFalse(resumeRunner.calls.contains { $0.0 == toolchain.da3.sfmTool.path })
    }

    func testPipelineFailsOnLowQuality() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img1.jpg"), value: 20)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img2.jpg"), value: 40)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img3.jpg"), value: 60)

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(metadata, paths: paths)

        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { try? self.writeFeatureDatabase(for: $0) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["matches_importer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                XCTAssertEqual(
                    self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: args),
                    "0"
                )
                try? self.writeVerifiedPairResults(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in
                try? self.writeSparseModel(at: projectURL, registeredImageCount: 2, pointCount: 100)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in
                try? self.writeSparseModel(at: projectURL, registeredImageCount: 2, pointCount: 100)
            }),
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, candidateRoute: .colmap),
            tooling: .init(runner: runner)
        )

        do {
            try await pipeline.run { _ in }
            XCTFail("Expected under-covered geometry to fail")
        } catch {
            guard case .geometryConditioningRejected(let failure) =
                    error as? PipelineRunner.PipelineError,
                  case .collapsedCameraTrajectory = failure else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let featureRuns = runner.calls.filter { $0.0 == toolchain.colmap.path && $0.1.first == "feature_extractor" }
        XCTAssertEqual(featureRuns.count, 1)
        XCTAssertEqual(runner.calls.filter { $0.1.first == "matches_importer" }.count, 1)
        let mapperCalls = runner.calls.filter { $0.1.first == "mapper" }
        XCTAssertEqual(mapperCalls.count, 2)
        XCTAssertEqual(
            mapperCalls.compactMap {
                value(for: "--Mapper.ba_global_frames_ratio", in: $0.1)
            },
            ["1.4", "1.1"]
        )
        XCTAssertEqual(
            runner.calls.filter { $0.1.first == "model_analyzer" }.count,
            0,
            "Conditioning rejects a two-camera model before the external summary is trusted."
        )
    }

    func testPipelineFailsOnMissingImages() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        try writeTestImage(
            url: sourcePhotos.appendingPathComponent("img0.jpg"),
            value: 42
        )

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(metadata, paths: paths)
        try FileManager.default.removeItem(
            at: paths.importedPhotosURL.appendingPathComponent("photo-0000.jpg")
        )

        let toolchain = try makeToolchain(root: temp)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "no images"), onRun: nil)
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, candidateRoute: .colmap),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync {
            try await pipeline.run { _ in }
        }
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testPipelineFailsWhenOnlyTwoUsableImagesRemain() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("TwoImages.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img0.jpg"), value: 42)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img1.jpg"), value: 84)

        let metadata = ProjectMetadata(
            title: "TwoImages",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(metadata, paths: paths)

        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [])
        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, skipTraining: true),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync {
            try await pipeline.run { _ in }
        }

        let saved = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(saved.state.lastError, "At least 3 usable photos or video frames are required.")
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testPipelineFailsOnMatcherError() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img1.jpg"), value: 20)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img2.jpg"), value: 40)
        try writeTestImage(url: sourcePhotos.appendingPathComponent("img3.jpg"), value: 60)

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(metadata, paths: paths)

        let toolchain = try makeToolchain(root: temp)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { try? self.writeFeatureDatabase(for: $0) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["matches_importer"], result: .init(exitCode: 1, terminationReason: .exit, stdout: "", stderr: "database is locked"), onRun: nil),
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, candidateRoute: .colmap),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync {
            try await pipeline.run { _ in }
        }
        XCTAssertEqual(runner.calls.map { $0.1.first }, ["feature_extractor", "matches_importer"])
    }

    private func writeTestImage(url: URL, value: UInt8) throws {
        try writeTestImage(url: url, width: 32, height: 32, value: value)
    }

    private func writeTestImage(
        url: URL,
        width: Int,
        height: Int,
        value: UInt8
    ) throws {
        var pixels = [UInt8](repeating: value, count: width * height)
        let data = Data(bytes: &pixels, count: pixels.count)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        _ = CGImageDestinationFinalize(destination)
    }

    private func resolvedFixturePlan(
        input: InputSpec,
        options: RequestedRunOptions
    ) -> ResolvedRunPlan {
        RunPlanResolver.resolve(
            requestedOptions: options,
            input: input,
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: .none
        )
    }

    private func makeAuthenticatedPhotoSelectionFixture(
        in root: URL,
        name: String,
        photoCount: Int,
        inputOrdering: InputOrdering,
        photoSelection: PhotoSelection,
        admissionBudget: Int,
        productionPath: PhotoAdmissionPathProbe = PhotoAdmissionPathProbe()
    ) async throws -> (
        paths: ProjectPaths,
        admissionPlan: ResolvedRunPlan,
        projection: PhotoSelectionProjection,
        toolchain: ToolchainPaths,
        productionPath: PhotoAdmissionPathProbe
    ) {
        let sourcePhotos = try writeVisualPhotoSources(
            in: root,
            name: "\(name)-SourcePhotos",
            count: photoCount
        )
        let options = RequestedRunOptions(
            detailProfile: .fast,
            inputOrdering: inputOrdering,
            photoSelection: photoSelection
        )
        let requestedInput = InputSpec.photos(folder: sourcePhotos.path)
        var admissionPlan = resolvedFixturePlan(
            input: requestedInput,
            options: options
        )
        admissionPlan.keyframeBudget = admissionBudget
        let paths = ProjectPaths(
            root: root.appendingPathComponent(
                "\(name).easysplatproj",
                isDirectory: true
            )
        )
        try FileManager.default.createDirectory(
            at: paths.root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var adoption = ProjectInputAdoption(requestedInput: requestedInput)
        try await adoptPhotoFixtures(
            sourcePhotos,
            plan: admissionPlan,
            paths: paths,
            adoption: &adoption,
            productionPath: productionPath
        )
        let saved = ProjectMetadata(
            title: name,
            input: adoption.input,
            photoInputReceipts: try XCTUnwrap(adoption.photoInputReceipts),
            photoSelectionReceipt: try XCTUnwrap(adoption.photoSelectionReceipt),
            requestedRunOptions: options,
            resolvedRunPlan: admissionPlan
        )
        try ProjectMetadataStore.save(saved, to: paths.metadataURL)
        try PhotoInputReceiptValidator.validateFiles(metadata: saved, paths: paths)
        let projection = try XCTUnwrap(
            PhotoSelectionProjection.loadVerified(metadata: saved, paths: paths)
        )
        return (
            paths,
            admissionPlan,
            projection,
            try makeToolchain(root: root),
            productionPath
        )
    }

    private func writeVisualPhotoSources(
        in root: URL,
        name: String,
        count: Int
    ) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        for index in 0..<count {
            try writeRetrievalTestImage(
                url: directory.appendingPathComponent(
                    String(format: "photo-%03d.jpg", index)
                ),
                index: index
            )
        }
        return directory
    }

    private func adoptPhotoFixtures(
        _ sourcePhotos: URL,
        plan: ResolvedRunPlan,
        paths: ProjectPaths,
        adoption: inout ProjectInputAdoption,
        productionPath: PhotoAdmissionPathProbe
    ) async throws {
        let prepared = try await PhotoInputPreflight.prepare(
            folder: sourcePhotos,
            stagingParent: paths.root.deletingLastPathComponent(),
            photoSelection: plan.photoSelection,
            inputOrdering: plan.inputOrdering,
            keyframeBudget: plan.keyframeBudget,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(
                maximumPhotoCount: 64,
                maximumTotalBytes: 128 * 1_024 * 1_024,
                maximumSinglePhotoBytes: 8 * 1_024 * 1_024,
                maximumPixelCount: 4_096 * 4_096,
                maximumDecodedDimension: 256,
                maximumTraversalEntryCount: 128,
                maximumRecursionDepth: 8,
                minimumFreeSpaceReserveBytes: 0
            ),
            progress: { _, _ in }
        )
        defer { prepared.discard() }
        productionPath.recordPreflight(prepared)
        try adoption.adoptPhotos(prepared, into: paths)
        productionPath.recordAdoption(adoption)
    }

    private func assertProductionPhotoAdmission(
        _ productionPath: PhotoAdmissionPathProbe,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(productionPath.preflightCount, 1, file: file, line: line)
        XCTAssertEqual(productionPath.adoptionCount, 1, file: file, line: line)
    }

    private func assertSelectedPhotoMappings(
        _ mappings: [PipelineRunner.SelectedFrameMapping],
        match receipts: [PhotoInputReceipt],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(mappings.count, receipts.count, file: file, line: line)
        XCTAssertTrue(
            mappings.allSatisfy {
                !$0.isVideo
                    && $0.groupId == "photos"
                    && $0.timestampSeconds == nil
                    && $0.videoSource == nil
                    && $0.videoOrigin == nil
            },
            file: file,
            line: line
        )
        XCTAssertEqual(
            mappings.map(\.sourceProjectRelativePath),
            receipts.map { Optional($0.projectRelativePath) },
            file: file,
            line: line
        )
        XCTAssertEqual(
            mappings.map(\.sourceSHA256),
            receipts.map { Optional($0.sha256) },
            file: file,
            line: line
        )
        XCTAssertEqual(
            mappings.map(\.photoRetainedRank),
            receipts.map { Optional($0.retainedRank) },
            file: file,
            line: line
        )
        XCTAssertTrue(
            mappings.allSatisfy {
                $0.selectedSHA256 != nil
                    && $0.selectedPixelSHA256 != nil
                    && $0.normalization != nil
            },
            file: file,
            line: line
        )
    }

    private func persistCurrentSelectedPhotoFixture(
        sources: [URL],
        paths: ProjectPaths,
        plan: ResolvedRunPlan
    ) throws {
        let metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let projection = try XCTUnwrap(
            PhotoSelectionProjection.loadVerified(metadata: metadata, paths: paths)
        )
        let projectedReceipts = try projection.project(
            targetCount: sources.count
        )
        let mappings = try projectedReceipts.enumerated().map { index, receipt in
            let source = try paths.resolveProjectRelativePath(
                receipt.projectRelativePath
            )
            guard let sourceRef = CGImageSourceCreateWithURL(source as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(sourceRef, 0, nil)
                    as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0,
                  height > 0 else {
                throw NSError(domain: "PipelineIntegrationTests", code: 41)
            }
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let scoredExposure = try FrameScoring.scoreFrame(at: source).lowLightExposureEV
            let exposure = scoredExposure > 0 ? scoredExposure : nil
            let sourceProjectRelativePath = try paths.projectRelativePath(for: source)
            XCTAssertEqual(
                try GeometryArtifactStore.sha256(of: source),
                receipt.sha256
            )
            let outputName = String(format: "frame_%06d.jpg", index)
            let selected = paths.framesSelectedURL.appendingPathComponent(outputName)
            let normalization = PipelineRunner.SelectedFrameNormalization(
                sourcePixelWidth: width,
                sourcePixelHeight: height,
                sourceOrientation: orientation,
                maximumPixelDimension: plan.maximumImageDimension,
                outputPixelWidth: width,
                outputPixelHeight: height,
                outputFormat: "jpg",
                transcoded: exposure != nil
            )
            try PipelineRunner.reproduceSelectedFrame(
                source: source,
                destination: selected,
                normalization: normalization,
                exposureEV: exposure
            )
            return PipelineRunner.SelectedFrameMapping(
                outputFileName: outputName,
                groupId: "photos",
                isVideo: false,
                lowLightExposureEV: exposure,
                sourceProjectRelativePath: sourceProjectRelativePath,
                sourceSHA256: receipt.sha256,
                photoRetainedRank: receipt.retainedRank,
                selectedSHA256: try GeometryArtifactStore.sha256(of: selected),
                selectedPixelSHA256: try PipelineRunner.selectedFramePixelSHA256(
                    at: selected
                ),
                normalization: normalization
            )
        }
        try JSONEncoder().encode(mappings).write(
            to: paths.framesSelectedManifestURL,
            options: .atomic
        )
    }

    private func writeRetrievalTestImage(url: URL, index: Int) throws {
        let size = 32
        var pixels = [UInt8](repeating: 96, count: size * size)
        let markerX = (index * 7) % (size - 3)
        let markerY = (index * 11) % (size - 3)
        for y in markerY..<(markerY + 3) {
            for x in markerX..<(markerX + 3) {
                pixels[y * size + x] = UInt8(128 + index % 96)
            }
        }
        let data = Data(pixels)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: size,
                height: size,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: size,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.jpeg.identifier as CFString,
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

    private func writeDisconnectedRetrievalTestImage(url: URL, index: Int) throws {
        let size = 32
        let verticalCluster = index < 60
        var pixels = [UInt8](repeating: 0, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let high = verticalCluster ? x >= size / 2 : y >= size / 2
                pixels[y * size + x] = high ? 232 : 24
            }
        }
        let marker = (index * 13) % pixels.count
        pixels[marker] = UInt8(80 + index % 120)
        let data = Data(pixels)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: size,
                height: size,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: size,
                space: colorSpace,
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

    private func writeSparseModel(
        at projectURL: URL,
        registeredImageCount: Int? = nil,
        pointCount: Int = 20,
        cameraModel: String = "SIMPLE_RADIAL"
    ) throws {
        let modelURL = projectURL.appendingPathComponent("SfM/colmap/sparse/0", isDirectory: true)
        let selectedNames = selectedImageNames(in: ProjectPaths(root: projectURL))
        let imageNames = registeredImageCount.map {
            Array(selectedNames.prefix(max(0, $0)))
        } ?? selectedNames
        let safeImageNames = imageNames.isEmpty ? ["frame_000000.jpg"] : imageNames
        try writeDa3SparseModel(
            at: modelURL,
            imageNames: safeImageNames,
            pointCount: pointCount,
            cameraModel: cameraModel
        )
    }

    private func writeSparseModel(
        at modelURL: URL,
        imageName: String,
        cameraModel: String = "SIMPLE_RADIAL"
    ) throws {
        try writeSparseModel(
            at: modelURL,
            imageNames: [imageName],
            cameraModel: cameraModel
        )
    }

    private func writeSparseModel(
        at modelURL: URL,
        imageNames: [String],
        cameraModel: String = "SIMPLE_RADIAL"
    ) throws {
        let safeImageNames = imageNames.isEmpty ? ["frame_000000.jpg"] : imageNames
        try writeDa3SparseModel(
            at: modelURL,
            imageNames: safeImageNames,
            pointCount: 20,
            cameraModel: cameraModel
        )
    }

    private func selectedImageNames(in paths: ProjectPaths) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(
            at: paths.framesSelectedURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
            .map(\.lastPathComponent)
            .sorted()
    }

    @discardableResult
    private func adoptVideoFixtures(
        _ sourceURLs: [URL],
        requestedOptions: RequestedRunOptions,
        paths: ProjectPaths,
        requestedInput suppliedInput: InputSpec? = nil,
        resolvedRunPlan suppliedPlan: ResolvedRunPlan? = nil
    ) async throws -> (
        adoption: ProjectInputAdoption,
        input: InputSpec,
        receipts: [VideoInputReceipt]
    ) {
        let requestedInput = suppliedInput
            ?? InputSpec.video(files: sourceURLs.map(\.path))
        guard requestedInput.videoFiles == sourceURLs.map(\.path) else {
            throw NSError(domain: "PipelineIntegrationTests", code: 45)
        }
        let plan = suppliedPlan ?? RunPlanResolver.resolve(
            requestedOptions: requestedOptions,
            input: requestedInput,
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: .none
        )
        let preflight = VideoInputPreflight(limits: .init(
            maximumVideoCount: 64,
            maximumTotalBytes: 1_024 * 1_024 * 1_024,
            minimumFreeSpaceReserveBytes: 0,
            maximumConcurrentDecoders: 2
        ))
        let prepared = try await preflight.prepare(
            videoURLs: sourceURLs,
            stagingParent: paths.root.deletingLastPathComponent(),
            requiredAtomicWorkspaceReserveBytes: 0,
            analysisPolicy: VideoFrameAnalysisPolicy(resolvedRunPlan: plan),
            pairingPolicy: plan.pairingPolicy,
            progress: { _, _ in }
        )
        defer { prepared.discard() }
        try FileManager.default.createDirectory(
            at: paths.root,
            withIntermediateDirectories: false
        )
        var adoption = ProjectInputAdoption(requestedInput: requestedInput)
        try adoption.adoptVideos(prepared, into: paths)
        return (
            adoption,
            adoption.input,
            try XCTUnwrap(adoption.videoInputReceipts)
        )
    }

    @discardableResult
    private func saveFixtureMetadata(
        _ metadata: ProjectMetadata,
        paths: ProjectPaths
    ) throws -> ProjectMetadata {
        guard let photoRoot = metadata.input.photosFolder else {
            try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
            return metadata
        }
        let plan = metadata.resolvedRunPlan ?? RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: .none
        )
        if photoRoot == "Originals/Photos" {
            var controlledMetadata = metadata
            controlledMetadata.resolvedRunPlan = plan
            try PhotoInputReceiptValidator.validateFiles(
                metadata: controlledMetadata,
                paths: paths
            )
            try ProjectMetadataStore.save(controlledMetadata, to: paths.metadataURL)
            return controlledMetadata
        }

        struct Candidate {
            let source: URL
            let safeDisplayName: String
            let byteCount: Int64
            let sha256: String
            let pixelWidth: Int
            let pixelHeight: Int
            let orientation: Int
            let typeIdentifier: String
            let fileExtension: String
            let analysisEvidence: PhotoAnalysisEvidence
        }

        let sourcePhotos = URL(fileURLWithPath: photoRoot, isDirectory: true)
        let fileManager = FileManager.default
        try paths.ensureDirectories()
        try? fileManager.removeItem(at: paths.importedPhotosURL)
        try fileManager.createDirectory(
            at: paths.importedPhotosURL,
            withIntermediateDirectories: true
        )

        let candidates = try fileManager.contentsOfDirectory(
            at: sourcePhotos,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
        var seenDigests = Set<String>()
        var analyzed: [Candidate] = []
        var unreadableCount = 0
        var exactDuplicateCount = 0
        for source in candidates {
            guard let values = try? source.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
                    as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
                  width > 0,
                  height > 0,
                  let sourceType = CGImageSourceGetType(imageSource) as String?,
                  let orientedImage = CGImageSourceCreateThumbnailAtIndex(
                    imageSource,
                    0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 256,
                    ] as CFDictionary
                  ) else {
                unreadableCount += 1
                continue
            }
            let typeIdentifier: String
            let fileExtension: String
            switch sourceType {
            case UTType.jpeg.identifier:
                typeIdentifier = UTType.jpeg.identifier
                fileExtension = "jpg"
            case UTType.png.identifier:
                typeIdentifier = UTType.png.identifier
                fileExtension = "png"
            case UTType.heic.identifier:
                typeIdentifier = UTType.heic.identifier
                fileExtension = "heic"
            case UTType.heif.identifier:
                typeIdentifier = UTType.heif.identifier
                fileExtension = "heif"
            default:
                unreadableCount += 1
                continue
            }
            let digest = try GeometryArtifactStore.sha256(of: source)
            guard seenDigests.insert(digest).inserted else {
                exactDuplicateCount += 1
                continue
            }
            let byteCount = try XCTUnwrap(
                (try fileManager.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?
                    .int64Value
            )
            analyzed.append(Candidate(
                source: source,
                safeDisplayName: source.lastPathComponent,
                byteCount: byteCount,
                sha256: digest,
                pixelWidth: width,
                pixelHeight: height,
                orientation: (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1,
                typeIdentifier: typeIdentifier,
                fileExtension: fileExtension,
                analysisEvidence: try PhotoAnalysisEvidenceBuilder.build(
                    sourceSHA256: digest,
                    orientedImage: orientedImage
                )
            ))
        }
        guard !analyzed.isEmpty else {
            throw NSError(domain: "PipelineIntegrationTests", code: 42)
        }

        let ordered = plan.inputOrdering == .continuous
            ? analyzed
            : analyzed.sorted { $0.sha256 < $1.sha256 }
        let strategy: PhotoSelectionStrategy
        let retainedInStrategyOrder: [Candidate]
        switch (plan.photoSelection, plan.inputOrdering) {
        case (.useAllValidPhotos, .continuous),
             (.useAllValidPhotos, .unordered):
            guard ordered.count <= plan.keyframeBudget else {
                throw PipelineRunner.PipelineError.photoSelectionExceedsBudget(
                    selected: ordered.count,
                    maximum: plan.keyframeBudget
                )
            }
            strategy = .useAll
            retainedInStrategyOrder = ordered
        case (.automatic, .continuous):
            strategy = .continuousEvenSpacing
            if ordered.count <= plan.keyframeBudget {
                retainedInStrategyOrder = ordered
            } else if plan.keyframeBudget == 1 {
                retainedInStrategyOrder = [ordered[ordered.count / 2]]
            } else {
                let step = Double(ordered.count - 1) / Double(plan.keyframeBudget - 1)
                retainedInStrategyOrder = (0..<plan.keyframeBudget).map { index in
                    ordered[Int((Double(index) * step).rounded())]
                }
            }
        case (.automatic, .unordered):
            strategy = .visualDiversity
            let rankedEvidence = try PhotoDiversitySelector.rank(
                ordered.map(\.analysisEvidence),
                targetCount: plan.keyframeBudget
            )
            let bySHA256 = Dictionary(
                uniqueKeysWithValues: ordered.map { ($0.sha256, $0) }
            )
            retainedInStrategyOrder = try rankedEvidence.map { evidence in
                try XCTUnwrap(bySHA256[evidence.sourceSHA256])
            }
        case (_, .automatic):
            throw NSError(domain: "PipelineIntegrationTests", code: 44)
        }

        let retainedRankBySHA256 = Dictionary(
            uniqueKeysWithValues: retainedInStrategyOrder.enumerated().map {
                ($0.element.sha256, $0.offset)
            }
        )
        let canonicalRetained = ordered.filter {
            retainedRankBySHA256[$0.sha256] != nil
        }
        let artifact = PhotoSelectionArtifact(
            strategy: strategy,
            analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
            analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256,
            selectorPolicyVersion: PhotoDiversitySelector.selectorPolicyVersion,
            selectorPolicySHA256: PhotoDiversitySelector.selectorPolicySHA256,
            inputOrdering: plan.inputOrdering,
            requestedPhotoSelection: plan.photoSelection,
            admissionCapacity: retainedInStrategyOrder.count,
            discoveredCount: candidates.count,
            acceptedCount: analyzed.count,
            unreadableCount: unreadableCount,
            exactDuplicateCount: exactDuplicateCount,
            companionDuplicateCount: 0,
            candidates: (plan.inputOrdering == .continuous ? analyzed : ordered)
                .enumerated()
                .map { ordinal, candidate in
                    PhotoSelectionCandidateArtifact(
                        admissionOrdinal: ordinal,
                        evidence: candidate.analysisEvidence,
                        retainedRank: retainedRankBySHA256[candidate.sha256]
                    )
                },
            retainedSourceSHA256s: retainedInStrategyOrder.map(\.sha256),
            canonicalRetainedSourceSHA256s: canonicalRetained.map(\.sha256)
        )
        let artifactFile = try PhotoSelectionArtifactStore.save(
            artifact,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths
        )

        var receipts: [PhotoInputReceipt] = []
        receipts.reserveCapacity(canonicalRetained.count)
        for (index, candidate) in canonicalRetained.enumerated() {
            let leaf = String(format: "photo-%04d.%@", index, candidate.fileExtension)
            let controlled = paths.importedPhotosURL.appendingPathComponent(leaf)
            try fileManager.copyItem(at: candidate.source, to: controlled)
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: controlled.path
            )
            receipts.append(PhotoInputReceipt(
                projectRelativePath: "Originals/Photos/\(leaf)",
                safeDisplayName: candidate.safeDisplayName,
                byteCount: candidate.byteCount,
                sha256: candidate.sha256,
                pixelWidth: candidate.pixelWidth,
                pixelHeight: candidate.pixelHeight,
                orientation: candidate.orientation,
                typeIdentifier: candidate.typeIdentifier,
                analysisEvidence: candidate.analysisEvidence,
                retainedRank: try XCTUnwrap(retainedRankBySHA256[candidate.sha256])
            ))
        }

        var controlledMetadata = metadata
        switch metadata.input {
        case .photos:
            controlledMetadata.input = .photos(folder: "Originals/Photos")
        case .mixed(let videos, _):
            controlledMetadata.input = .mixed(
                videos: videos,
                photosFolder: "Originals/Photos"
            )
        case .video:
            throw NSError(domain: "PipelineIntegrationTests", code: 43)
        }
        controlledMetadata.resolvedRunPlan = plan
        controlledMetadata.photoInputReceipts = receipts
        controlledMetadata.photoSelectionReceipt = PhotoSelectionReceipt(
            projectRelativePath: PhotoSelectionReceipt.projectRelativePath,
            byteCount: artifactFile.byteCount,
            sha256: artifactFile.sha256,
            artifactSchemaVersion: artifact.schemaVersion,
            analysisRecipeVersion: artifact.analysisRecipeVersion,
            analysisRecipeSHA256: artifact.analysisRecipeSHA256,
            selectorPolicyVersion: artifact.selectorPolicyVersion,
            selectorPolicySHA256: artifact.selectorPolicySHA256
        )
        try PhotoInputReceiptValidator.validateFiles(
            metadata: controlledMetadata,
            paths: paths
        )
        try ProjectMetadataStore.save(controlledMetadata, to: paths.metadataURL)
        return controlledMetadata
    }

    private func writeFeatureDatabase(
        for arguments: [String],
        reverseStableIDs: Bool = false
    ) throws {
        guard let databasePath = value(for: "--database_path", in: arguments),
              let imagePath = value(for: "--image_path", in: arguments) else {
            throw NSError(domain: "PipelineIntegrationTests", code: 10)
        }
        let databaseURL = URL(fileURLWithPath: databasePath)
        let imageNames = try FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: imagePath, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
        .map(\.lastPathComponent)
        .sorted()
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: databaseURL)

        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK,
              let database else {
            throw NSError(domain: "PipelineIntegrationTests", code: 11)
        }
        defer { sqlite3_close(database) }
        let schema = """
        CREATE TABLE cameras(
            camera_id INTEGER PRIMARY KEY,
            model INTEGER NOT NULL,
            width INTEGER NOT NULL,
            height INTEGER NOT NULL,
            params BLOB NOT NULL,
            prior_focal_length INTEGER NOT NULL
        );
        CREATE TABLE rigs(
            rig_id INTEGER PRIMARY KEY,
            ref_sensor_id INTEGER NOT NULL,
            ref_sensor_type INTEGER NOT NULL
        );
        CREATE UNIQUE INDEX rig_ref_sensor_assignment
            ON rigs(ref_sensor_id, ref_sensor_type);
        CREATE TABLE rig_sensors(
            rig_id INTEGER NOT NULL,
            sensor_id INTEGER NOT NULL,
            sensor_type INTEGER NOT NULL,
            sensor_from_rig BLOB
        );
        CREATE UNIQUE INDEX rig_sensor_assignment
            ON rig_sensors(sensor_id, sensor_type);
        CREATE TABLE frames(
            frame_id INTEGER PRIMARY KEY,
            rig_id INTEGER NOT NULL
        );
        CREATE TABLE frame_data(
            frame_id INTEGER NOT NULL,
            data_id INTEGER NOT NULL,
            sensor_id INTEGER NOT NULL,
            sensor_type INTEGER NOT NULL
        );
        CREATE UNIQUE INDEX frame_sensor_assignment
            ON frame_data(data_id, sensor_type);
        CREATE TABLE images(
            image_id INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE,
            camera_id INTEGER NOT NULL
        );
        CREATE TABLE pose_priors(
            pose_prior_id INTEGER PRIMARY KEY,
            corr_data_id INTEGER NOT NULL,
            corr_sensor_id INTEGER NOT NULL,
            corr_sensor_type INTEGER NOT NULL,
            position BLOB,
            position_covariance BLOB,
            gravity BLOB,
            coordinate_system INTEGER NOT NULL
        );
        CREATE UNIQUE INDEX pose_prior_data_assignment
            ON pose_priors(corr_data_id, corr_sensor_id, corr_sensor_type);
        CREATE TABLE keypoints(
            image_id INTEGER PRIMARY KEY,
            rows INTEGER NOT NULL,
            cols INTEGER NOT NULL,
            data BLOB
        );
        CREATE TABLE descriptors(
            image_id INTEGER PRIMARY KEY,
            rows INTEGER NOT NULL,
            cols INTEGER NOT NULL,
            data BLOB,
            type INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE matches(
            pair_id INTEGER PRIMARY KEY,
            rows INTEGER NOT NULL,
            cols INTEGER NOT NULL,
            data BLOB
        );
        CREATE TABLE two_view_geometries(
            pair_id INTEGER PRIMARY KEY,
            rows INTEGER NOT NULL,
            cols INTEGER NOT NULL,
            data BLOB
        );
        """
        try executeSQL(schema, in: database)

        var cameraStatement: OpaquePointer?
        var imageStatement: OpaquePointer?
        var keypointStatement: OpaquePointer?
        var descriptorStatement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO cameras(camera_id, model, width, height, params, prior_focal_length) VALUES (?, ?, ?, ?, ?, ?);",
            -1,
            &cameraStatement,
            nil
        ) == SQLITE_OK,
        sqlite3_prepare_v2(
            database,
            "INSERT INTO images(image_id, name, camera_id) VALUES (?, ?, ?);",
            -1,
            &imageStatement,
            nil
        ) == SQLITE_OK,
        sqlite3_prepare_v2(
            database,
            "INSERT INTO keypoints(image_id, rows, cols) VALUES (?, 64, 4);",
            -1,
            &keypointStatement,
            nil
        ) == SQLITE_OK,
        sqlite3_prepare_v2(
            database,
            "INSERT INTO descriptors(image_id, rows, cols, type) VALUES (?, 64, 128, 0);",
            -1,
            &descriptorStatement,
            nil
        ) == SQLITE_OK,
        let cameraStatement,
        let imageStatement,
        let keypointStatement,
        let descriptorStatement else {
            throw NSError(domain: "PipelineIntegrationTests", code: 12)
        }
        defer {
            sqlite3_finalize(cameraStatement)
            sqlite3_finalize(imageStatement)
            sqlite3_finalize(keypointStatement)
            sqlite3_finalize(descriptorStatement)
        }
        try executeSQL("BEGIN IMMEDIATE TRANSACTION;", in: database)
        do {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let sharesCamera = value(
                for: "--ImageReader.single_camera",
                in: arguments
            ) == "1"
            let cameraModel = value(
                for: "--ImageReader.camera_model",
                in: arguments
            ) ?? "SIMPLE_RADIAL"
            let modelContract: (id: Int32, focalCount: Int, parameterCount: Int)
            switch cameraModel {
            case "SIMPLE_PINHOLE": modelContract = (0, 1, 3)
            case "PINHOLE": modelContract = (1, 2, 4)
            case "SIMPLE_RADIAL": modelContract = (2, 1, 4)
            case "RADIAL": modelContract = (3, 1, 5)
            case "OPENCV": modelContract = (4, 2, 8)
            case "OPENCV_FISHEYE": modelContract = (5, 2, 8)
            default:
                throw NSError(domain: "PipelineIntegrationTests", code: 15)
            }
            let suppliedCameraParameters = value(
                for: "--ImageReader.camera_params",
                in: arguments
            ).map { value in
                value.split(separator: ",", omittingEmptySubsequences: false)
                    .compactMap { Double($0) }
            }
            if let suppliedCameraParameters,
               suppliedCameraParameters.count != modelContract.parameterCount {
                throw NSError(domain: "PipelineIntegrationTests", code: 20)
            }
            var insertedSharedCamera = false
            for (offset, imageName) in imageNames.enumerated() {
                let imageID = reverseStableIDs
                    ? Int32(imageNames.count - offset)
                    : Int32(offset + 1)
                let cameraID: Int32 = sharesCamera ? 1 : imageID
                let imageURL = URL(fileURLWithPath: imagePath, isDirectory: true)
                    .appendingPathComponent(imageName)
                guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                        as? [CFString: Any],
                      let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int32Value,
                      let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int32Value,
                      width > 0,
                      height > 0 else {
                    throw NSError(domain: "PipelineIntegrationTests", code: 16)
                }
                if !sharesCamera || !insertedSharedCamera {
                    var parameters = suppliedCameraParameters ?? Array(
                        repeating: 0.0,
                        count: modelContract.parameterCount
                    )
                    if suppliedCameraParameters == nil {
                        for index in 0..<modelContract.focalCount {
                            parameters[index] = Double(max(width, height))
                        }
                        parameters[modelContract.focalCount] = Double(width) / 2
                        parameters[modelContract.focalCount + 1] = Double(height) / 2
                    }
                    var parameterBytes = Data()
                    for value in parameters {
                        var bits = value.bitPattern.littleEndian
                        withUnsafeBytes(of: &bits) { parameterBytes.append(contentsOf: $0) }
                    }
                    sqlite3_bind_int(cameraStatement, 1, cameraID)
                    sqlite3_bind_int(cameraStatement, 2, modelContract.id)
                    sqlite3_bind_int(cameraStatement, 3, width)
                    sqlite3_bind_int(cameraStatement, 4, height)
                    let parameterBindResult = parameterBytes.withUnsafeBytes { bytes in
                        sqlite3_bind_blob(
                            cameraStatement,
                            5,
                            bytes.baseAddress,
                            Int32(bytes.count),
                            transient
                        )
                    }
                    guard parameterBindResult == SQLITE_OK else {
                        throw NSError(domain: "PipelineIntegrationTests", code: 17)
                    }
                    sqlite3_bind_int(
                        cameraStatement,
                        6,
                        suppliedCameraParameters == nil ? 0 : 1
                    )
                    guard sqlite3_step(cameraStatement) == SQLITE_DONE else {
                        throw NSError(domain: "PipelineIntegrationTests", code: 19)
                    }
                    sqlite3_reset(cameraStatement)
                    sqlite3_clear_bindings(cameraStatement)
                    try executeSQL(
                        "INSERT INTO rigs(rig_id, ref_sensor_id, ref_sensor_type) "
                            + "VALUES (\(cameraID), \(cameraID), 0);",
                        in: database
                    )
                    insertedSharedCamera = true
                }
                sqlite3_bind_int(imageStatement, 1, imageID)
                sqlite3_bind_text(imageStatement, 2, imageName, -1, transient)
                sqlite3_bind_int(imageStatement, 3, cameraID)
                guard sqlite3_step(imageStatement) == SQLITE_DONE else {
                    throw NSError(domain: "PipelineIntegrationTests", code: 18)
                }
                sqlite3_reset(imageStatement)
                sqlite3_clear_bindings(imageStatement)
                try executeSQL(
                    "INSERT INTO frames(frame_id, rig_id) "
                        + "VALUES (\(imageID), \(cameraID));",
                    in: database
                )
                try executeSQL(
                    "INSERT INTO frame_data(frame_id, data_id, sensor_id, sensor_type) "
                        + "VALUES (\(imageID), \(imageID), \(cameraID), 0);",
                    in: database
                )
                for statement in [keypointStatement, descriptorStatement] {
                    sqlite3_bind_int(statement, 1, imageID)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw NSError(domain: "PipelineIntegrationTests", code: 14)
                    }
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                }
            }
            try executeSQL("COMMIT;", in: database)
        } catch {
            sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    private func writeVocabularyOutput(
        for arguments: [String],
        connectQueries: Bool = false,
        pairLines: [String] = []
    ) throws {
        guard let outputPath = value(for: "--output_pair_list_path", in: arguments),
              let queryPath = value(for: "--query_image_list_path", in: arguments),
              let candidateCount = value(for: "--num_images", in: arguments)
                .flatMap(Int.init),
              let returnedNeighborCount = value(
                for: "--returned_neighbor_count",
                in: arguments
              ).flatMap(Int.init),
              let minimumFrameSeparation = value(
                for: "--minimum_frame_separation",
                in: arguments
              ).flatMap(Int.init),
              let queryStride = value(for: "--query_stride", in: arguments)
                .flatMap(Int.init),
              let requestDigest = value(for: "--request_digest", in: arguments) else {
            throw NSError(domain: "PipelineIntegrationTests", code: 15)
        }
        let queryNames = try String(contentsOfFile: queryPath, encoding: .utf8)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        var requestedPairs = pairLines
        if requestedPairs.isEmpty, connectQueries {
            requestedPairs = zip(queryNames, queryNames.dropFirst()).map {
                "\($0.0) \($0.1)"
            }
            if queryNames.count > 2,
               let first = queryNames.first,
               let last = queryNames.last {
                requestedPairs.append("\(last) \(first)")
            }
        }
        let excludedLines: [String]
        if let excludedPath = value(for: "--excluded_pair_list_path", in: arguments) {
            excludedLines = try String(contentsOfFile: excludedPath, encoding: .utf8)
                .split(whereSeparator: \.isNewline)
                .map(String.init)
        } else {
            excludedLines = []
        }

        struct Edge: Hashable {
            let first: String
            let second: String

            init?(_ line: String) {
                let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard fields.count == 2, fields[0] != fields[1] else { return nil }
                if fields[0] < fields[1] {
                    first = fields[0]
                    second = fields[1]
                } else {
                    first = fields[1]
                    second = fields[0]
                }
            }

            func other(than imageName: String) -> String? {
                if first == imageName { return second }
                if second == imageName { return first }
                return nil
            }
        }

        guard requestedPairs.allSatisfy({ Edge($0) != nil }),
              excludedLines.allSatisfy({ Edge($0) != nil }) else {
            throw NSError(domain: "PipelineIntegrationTests", code: 46)
        }
        let requestedEdges = requestedPairs.compactMap(Edge.init)
        let excludedEdges = Set(excludedLines.compactMap(Edge.init))
        let querySet = Set(queryNames)
        var neighborsByQuery = Dictionary(
            uniqueKeysWithValues: queryNames.map { ($0, Set<String>()) }
        )
        for edge in requestedEdges {
            if querySet.contains(edge.first) {
                neighborsByQuery[edge.first, default: []].insert(edge.second)
            }
            if querySet.contains(edge.second) {
                neighborsByQuery[edge.second, default: []].insert(edge.first)
            }
        }
        let outcomes = queryNames.map { queryName in
            let neighbors = Array(neighborsByQuery[queryName] ?? [])
                .sorted(by: PairGraphEvidenceStore.canonicalUTF8Less)
            return PairGraphRetrievalQueryOutcome(
                queryImageName: queryName,
                status: neighbors.isEmpty ? .noRankedNeighbors : .ranked,
                rankedNeighborImageNames: neighbors
            )
        }
        var emittedEdges: Set<Edge> = []
        var directedPairLines: [String] = []
        for outcome in outcomes {
            for neighbor in outcome.rankedNeighborImageNames {
                guard let edge = Edge("\(outcome.queryImageName) \(neighbor)"),
                      !excludedEdges.contains(edge),
                      emittedEdges.insert(edge).inserted else {
                    continue
                }
                directedPairLines.append("\(outcome.queryImageName) \(neighbor)")
            }
        }
        directedPairLines.sort(by: PairGraphEvidenceStore.canonicalUTF8Less)
        let evidence = PairGraphRetrievalAttemptEvidence(
            engine: .localSiftVocabularyV2,
            queryImageNames: queryNames,
            queryStride: queryStride,
            candidateCount: candidateCount,
            returnedNeighborCount: returnedNeighborCount,
            minimumFrameSeparation: minimumFrameSeparation,
            queryOutcomes: outcomes,
            directedPairLines: directedPairLines
        )
        guard PairGraphEvidenceStore.retrievalRequestDigest(evidence)
                == requestDigest else {
            throw NSError(domain: "PipelineIntegrationTests", code: 47)
        }
        try (PairGraphEvidenceStore.retrievalContractLines(evidence)
            .joined(separator: "\n") + "\n").write(
            to: URL(fileURLWithPath: outputPath),
            atomically: true,
            encoding: .utf8
        )
    }

    private func noNeighborVocabularyScript(
        colmapPath: String
    ) -> MockSubprocessRunner.Script {
        .init(
            path: colmapPath,
            argsPrefix: ["local_vocab_retriever"],
            result: .init(
                exitCode: 0,
                terminationReason: .exit,
                stdout: "",
                stderr: ""
            ),
            onRun: { arguments in
                guard let outputPath = self.value(
                    for: "--output_pair_list_path",
                    in: arguments
                ),
                      let queryPath = self.value(
                        for: "--query_image_list_path",
                        in: arguments
                      ),
                      let candidateCount = self.value(
                        for: "--num_images",
                        in: arguments
                      ).flatMap(Int.init),
                      let returnedNeighborCount = self.value(
                        for: "--returned_neighbor_count",
                        in: arguments
                      ).flatMap(Int.init),
                      let minimumFrameSeparation = self.value(
                        for: "--minimum_frame_separation",
                        in: arguments
                      ).flatMap(Int.init),
                      let queryStride = self.value(
                        for: "--query_stride",
                        in: arguments
                      ).flatMap(Int.init),
                      let requestDigest = self.value(
                        for: "--request_digest",
                        in: arguments
                      ) else {
                    throw NSError(
                        domain: "PipelineIntegrationTests",
                        code: 44
                    )
                }
                let queryImageNames = try String(
                    contentsOf: URL(fileURLWithPath: queryPath),
                    encoding: .utf8
                ).split(whereSeparator: \.isNewline).map(String.init)
                let evidence = PairGraphRetrievalAttemptEvidence(
                    engine: .localSiftVocabularyV2,
                    queryImageNames: queryImageNames,
                    queryStride: queryStride,
                    candidateCount: candidateCount,
                    returnedNeighborCount: returnedNeighborCount,
                    minimumFrameSeparation: minimumFrameSeparation,
                    queryOutcomes: queryImageNames.map {
                        PairGraphRetrievalQueryOutcome(
                            queryImageName: $0,
                            status: .noRankedNeighbors,
                            rankedNeighborImageNames: []
                        )
                    },
                    directedPairLines: []
                )
                guard PairGraphEvidenceStore.retrievalRequestDigest(evidence)
                        == requestDigest else {
                    throw NSError(
                        domain: "PipelineIntegrationTests",
                        code: 45
                    )
                }
                try (PairGraphEvidenceStore.retrievalContractLines(evidence)
                    .joined(separator: "\n") + "\n").write(
                        to: URL(fileURLWithPath: outputPath),
                        atomically: true,
                        encoding: .utf8
                    )
            }
        )
    }

    private func makePhotoRecoveryProject(
        in root: URL,
        name: String,
        photoCount: Int = 60,
        inputOrdering: InputOrdering = .unordered,
        photoSelection: PhotoSelection = .useAllValidPhotos,
        detailProfile: DetailProfile = .fast
    ) throws -> (
        projectURL: URL,
        paths: ProjectPaths,
        toolchain: ToolchainPaths
    ) {
        let projectURL = root.appendingPathComponent(
            "\(name).easysplatproj",
            isDirectory: true
        )
        let sourcePhotos = root.appendingPathComponent(
            "\(name)-SourcePhotos",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sourcePhotos,
            withIntermediateDirectories: true
        )
        for index in 0..<photoCount {
            try writeTestImage(
                url: sourcePhotos.appendingPathComponent("img\(index).jpg"),
                value: UInt8(index)
            )
        }
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(
            ProjectMetadata(
                title: name,
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    detailProfile: detailProfile,
                    inputOrdering: inputOrdering,
                    photoSelection: photoSelection
                )
            ),
            paths: paths
        )
        return (projectURL, paths, try makeToolchain(root: root))
    }

    private func makeDa3RecoveryProject(
        in root: URL,
        name: String,
        photoCount: Int = 20
    ) throws -> (
        projectURL: URL,
        paths: ProjectPaths,
        toolchain: ToolchainPaths
    ) {
        let projectURL = root.appendingPathComponent(
            "\(name).easysplatproj",
            isDirectory: true
        )
        let sourcePhotos = root.appendingPathComponent(
            "\(name)-SourcePhotos",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sourcePhotos,
            withIntermediateDirectories: true
        )
        for index in 0..<photoCount {
            try writeRetrievalTestImage(
                url: sourcePhotos.appendingPathComponent(
                    String(format: "img_%03d.jpg", index)
                ),
                index: index
            )
        }
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try saveFixtureMetadata(
            ProjectMetadata(
                title: name,
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    capturePath: .orbit,
                    detailProfile: .fast,
                    cameraGrouping: .sameCameraAndLens,
                    inputOrdering: .continuous,
                    photoSelection: .useAllValidPhotos
                )
            ),
            paths: paths
        )
        return (
            projectURL,
            paths,
            try makeToolchain(root: root, createDa3Files: true)
        )
    }

    private func makePhotoRecoveryPipeline(
        projectURL: URL,
        toolchain: ToolchainPaths,
        scripts: [MockSubprocessRunner.Script],
        stopAfterStage: PipelineStage? = nil
    ) -> (pipeline: PipelineRunner, runner: MockSubprocessRunner) {
        let runner = MockSubprocessRunner(scripts: scripts)
        return (
            PipelineRunner(
                projectURL: projectURL,
                config: makePipelineConfig(
                    toolchain: toolchain,
                    candidateRoute: .colmap,
                    skipTraining: true,
                    stopAfterStage: stopAfterStage
                ),
                tooling: .init(runner: runner)
            ),
            runner
        )
    }

    private func successfulMappingScripts(
        colmapPath: String,
        projectURL: URL,
        registeredViews: Int,
        totalViews: Int,
        pointCount: Int
    ) -> [MockSubprocessRunner.Script] {
        let observationCount = registeredViews * pointCount
        return [
            .init(
                path: colmapPath,
                argsPrefix: ["mapper"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "",
                    stderr: ""
                ),
                stdoutLines: ["Retriangulation and Global bundle adjustment"],
                onRun: { _ in
                    try self.writeSparseModel(
                        at: projectURL,
                        registeredImageCount: registeredViews,
                        pointCount: pointCount
                    )
                }
            ),
            .init(
                path: colmapPath,
                argsPrefix: ["model_analyzer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: \(registeredViews) / \(totalViews)\nPoints: \(pointCount)\nObservations: \(observationCount)\nMean track length: \(registeredViews).0\nMean reprojection error: 0.5\n",
                    stderr: ""
                )
            ),
        ]
    }

    private func writeFiftyNinePlusOneFaissResults(
        for arguments: [String]
    ) throws {
        try writeDominantFaissResults(
            for: arguments,
            dominantViewCount: 59
        )
    }

    private func writeFiftyThreePlusSevenFaissResults(
        for arguments: [String]
    ) throws {
        try writeDominantFaissResults(
            for: arguments,
            dominantViewCount: 53
        )
    }

    private func writeFiftySevenPlusThreeOrderedFaissResults(
        for arguments: [String]
    ) throws {
        let lines = try pairListLines(for: arguments)
        let imageNames = Set(lines.flatMap {
            $0.split(whereSeparator: \.isWhitespace).map(String.init)
        }).sorted()
        guard imageNames.count == 60 else {
            throw NSError(domain: "PipelineIntegrationTests", code: 29)
        }
        let dominantNames = Set(imageNames.prefix(57))
        let minorNames = Set(imageNames.suffix(3))
        let verified = Set(lines.filter { line in
            let names = line.split(whereSeparator: \.isWhitespace).map(String.init)
            return names.allSatisfy(dominantNames.contains)
                || names.allSatisfy(minorNames.contains)
        })
        guard !verified.isEmpty else {
            throw NSError(domain: "PipelineIntegrationTests", code: 30)
        }
        try writeSelectiveVerifiedPairResults(
            for: arguments,
            verifiedPairLines: verified
        )
    }

    private func writeDominantFaissResults(
        for arguments: [String],
        dominantViewCount: Int
    ) throws {
        let lines = try pairListLines(for: arguments)
        guard lines.count == 1_770 else {
            throw NSError(domain: "PipelineIntegrationTests", code: 26)
        }
        let imageNames = Set(lines.flatMap {
            $0.split(whereSeparator: \.isWhitespace).map(String.init)
        }).sorted()
        guard dominantViewCount > 1,
              dominantViewCount < imageNames.count else {
            throw NSError(domain: "PipelineIntegrationTests", code: 27)
        }
        let dominantNames = Set(imageNames.prefix(dominantViewCount))
        let verified = Set(lines.filter { line in
            line.split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .allSatisfy(dominantNames.contains)
        }.prefix(230))
        guard verified.count == 230 else {
            throw NSError(domain: "PipelineIntegrationTests", code: 28)
        }
        try writeSelectiveVerifiedPairResults(
            for: arguments,
            verifiedPairLines: verified
        )
    }

    private func writeVerifiedPairResults(
        for arguments: [String],
        verifiedRows: Int = ColmapMappingPolicy.minimumPairInlierCount,
        verifiedPairLines: Set<String>? = nil
    ) throws {
        guard let databasePath = value(for: "--database_path", in: arguments),
              value(for: "--match_list_path", in: arguments) != nil else {
            throw NSError(domain: "PipelineIntegrationTests", code: 16)
        }
        let pairs = try pairListLines(for: arguments)
            .map { line -> (line: String, first: String, second: String) in
                let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
                guard fields.count == 2 else { return (line, "", "") }
                return (line, fields[0], fields[1])
            }
        guard pairs.allSatisfy({ !$0.first.isEmpty && !$0.second.isEmpty }) else {
            throw NSError(domain: "PipelineIntegrationTests", code: 17)
        }

        var database: OpaquePointer?
        guard sqlite3_open(databasePath, &database) == SQLITE_OK,
              let database else {
            throw NSError(domain: "PipelineIntegrationTests", code: 18)
        }
        defer { sqlite3_close(database) }
        var imageStatement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT image_id, name FROM images;",
            -1,
            &imageStatement,
            nil
        ) == SQLITE_OK,
        let imageStatement else {
            throw NSError(domain: "PipelineIntegrationTests", code: 19)
        }
        defer { sqlite3_finalize(imageStatement) }
        var imageIDs: [String: Int64] = [:]
        while sqlite3_step(imageStatement) == SQLITE_ROW {
            let imageID = sqlite3_column_int64(imageStatement, 0)
            guard let nameBytes = sqlite3_column_text(imageStatement, 1) else {
                throw NSError(domain: "PipelineIntegrationTests", code: 20)
            }
            imageIDs[String(cString: nameBytes)] = imageID
        }
        var descriptorStatement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT image_id, rows FROM descriptors;",
            -1,
            &descriptorStatement,
            nil
        ) == SQLITE_OK,
        let descriptorStatement else {
            throw NSError(domain: "PipelineIntegrationTests", code: 29)
        }
        defer { sqlite3_finalize(descriptorStatement) }
        var descriptorRowsByImageID: [Int64: Int64] = [:]
        while sqlite3_step(descriptorStatement) == SQLITE_ROW {
            descriptorRowsByImageID[sqlite3_column_int64(descriptorStatement, 0)] =
                sqlite3_column_int64(descriptorStatement, 1)
        }

        try executeSQL(
            "DELETE FROM matches; DELETE FROM two_view_geometries; BEGIN IMMEDIATE TRANSACTION;",
            in: database
        )
        do {
            for pair in pairs {
                let firstName = pair.first
                let secondName = pair.second
                guard let firstID = imageIDs[firstName], let secondID = imageIDs[secondName] else {
                    throw NSError(domain: "PipelineIntegrationTests", code: 21)
                }
                let low = min(firstID, secondID)
                let high = max(firstID, secondID)
                let pairID = low * ColmapPairGraphInspector.pairIDDivisor + high
                let pairHasDescriptors = descriptorRowsByImageID[firstID].map { $0 > 0 } == true
                    && descriptorRowsByImageID[secondID].map { $0 > 0 } == true
                let pairVerifiedRows = pairHasDescriptors
                    ? (verifiedPairLines
                        .map { $0.contains(pair.line) ? verifiedRows : 0 }
                        ?? verifiedRows)
                    : 0
                let rawRows = pairHasDescriptors
                    ? max(ColmapMappingPolicy.minimumPairInlierCount, pairVerifiedRows)
                    : 0
                try executeSQL(
                    "INSERT INTO matches(pair_id, rows, cols) VALUES (\(pairID), \(rawRows), 2);" +
                    "INSERT INTO two_view_geometries(pair_id, rows, cols) VALUES (\(pairID), \(pairVerifiedRows), 2);",
                    in: database
                )
            }
            try executeSQL("COMMIT;", in: database)
        } catch {
            sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    private func leavePersistentWALResidue(for arguments: [String]) throws {
        guard let databasePath = value(for: "--database_path", in: arguments) else {
            throw NSError(domain: "PipelineIntegrationTests", code: 42)
        }
        var database: OpaquePointer?
        guard sqlite3_open(databasePath, &database) == SQLITE_OK,
              let database else {
            throw NSError(domain: "PipelineIntegrationTests", code: 43)
        }
        var persistWAL: Int32 = 1
        guard sqlite3_exec(
            database,
            "PRAGMA journal_mode = WAL; PRAGMA wal_autocheckpoint = 0;",
            nil,
            nil,
            nil
        ) == SQLITE_OK,
        sqlite3_file_control(
            database,
            "main",
            SQLITE_FCNTL_PERSIST_WAL,
            &persistWAL
        ) == SQLITE_OK,
        sqlite3_exec(database, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil)
            == SQLITE_OK,
        sqlite3_close(database) == SQLITE_OK else {
            sqlite3_close(database)
            throw NSError(domain: "PipelineIntegrationTests", code: 44)
        }
    }

    private func markLastImageDescriptorless(for arguments: [String]) throws {
        guard let databasePath = value(for: "--database_path", in: arguments) else {
            throw NSError(domain: "PipelineIntegrationTests", code: 30)
        }
        var database: OpaquePointer?
        guard sqlite3_open(databasePath, &database) == SQLITE_OK,
              let database else {
            throw NSError(domain: "PipelineIntegrationTests", code: 31)
        }
        defer { sqlite3_close(database) }
        try executeSQL(
            "UPDATE descriptors SET rows = 0 WHERE image_id = (SELECT MAX(image_id) FROM images);",
            in: database
        )
    }

    private func pairListLines(for arguments: [String]) throws -> [String] {
        guard let pairListPath = value(for: "--match_list_path", in: arguments) else {
            throw NSError(domain: "PipelineIntegrationTests", code: 22)
        }
        return try String(contentsOfFile: pairListPath, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
    }

    private func writeSelectiveVerifiedPairResults(
        for arguments: [String],
        verifiedPairLines: Set<String>
    ) throws {
        try writeVerifiedPairResults(
            for: arguments,
            verifiedRows: ColmapMappingPolicy.minimumPairInlierCount,
            verifiedPairLines: verifiedPairLines
        )
    }

    private func matchingRowCounts(databasePath: String) throws -> [Int] {
        var database: OpaquePointer?
        guard sqlite3_open(databasePath, &database) == SQLITE_OK,
              let database else {
            throw NSError(domain: "PipelineIntegrationTests", code: 23)
        }
        defer { sqlite3_close(database) }
        return try ["matches", "two_view_geometries"].map { table in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                database,
                "SELECT COUNT(*) FROM \(table);",
                -1,
                &statement,
                nil
            ) == SQLITE_OK,
            let statement else {
                throw NSError(domain: "PipelineIntegrationTests", code: 24)
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw NSError(domain: "PipelineIntegrationTests", code: 25)
            }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func executeSQL(_ sql: String, in database: OpaquePointer) throws {
        var message: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(database, sql, nil, nil, &message) == SQLITE_OK else {
            let description = message.map { String(cString: $0) }
                ?? "SQLite error \(sqlite3_errcode(database))"
            sqlite3_free(message)
            throw NSError(
                domain: "PipelineIntegrationTests",
                code: Int(sqlite3_errcode(database)),
                userInfo: [NSLocalizedDescriptionKey: description]
            )
        }
    }

    private func writeProcessedPairCount(into databaseURL: URL, pairCount: Int) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK, let db else {
            XCTFail("Unable to open sqlite database at \(databaseURL.path)")
            return
        }
        guard sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS two_view_geometries(pair_id INTEGER PRIMARY KEY);", nil, nil, nil) == SQLITE_OK else {
            XCTFail("Unable to create two_view_geometries table")
            return
        }
        guard sqlite3_exec(db, "DELETE FROM two_view_geometries;", nil, nil, nil) == SQLITE_OK else {
            XCTFail("Unable to clear two_view_geometries table")
            return
        }
        guard sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
            XCTFail("Unable to begin sqlite transaction")
            return
        }
        for index in 0..<max(0, pairCount) {
            let sql = "INSERT INTO two_view_geometries(pair_id) VALUES(\(index + 1));"
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                XCTFail("Unable to insert sqlite row \(index + 1)")
                return
            }
        }
        guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            XCTFail("Unable to commit sqlite transaction")
            return
        }
    }

    private func persistGeometryArtifactFixture(
        metadata: inout ProjectMetadata,
        paths: ProjectPaths,
        runtimeClosure: ColmapRuntimeClosureEvidence
    ) throws {
        if metadata.resolvedRunPlan == nil {
            metadata.resolvedRunPlan = RunPlanResolver.resolve(
                requestedOptions: metadata.requestedRunOptions,
                input: metadata.input,
                hardware: HardwareProfile(
                    memoryGB: 48,
                    cpuCount: 16,
                    gpuWorkingSetGB: 36
                ),
                developmentOverrides: .none
            )
        }
        let workerBudget = try XCTUnwrap(
            metadata.resolvedRunPlan?.geometryWorkerBudget
        )
        let imageNames = selectedImageNames(in: paths)
        let pairGraphEvidence = try persistPairGraphEvidenceFixture(
            paths: paths,
            imageNames: imageNames
        )
        let acceptedPairAttempt = try XCTUnwrap(pairGraphEvidence.attempts.last)
        let pairGraphArtifact = try pairGraphEvidence.pairGraphArtifact()
        let matchingDatabaseDigest = try XCTUnwrap(
            pairGraphArtifact.measurement?.matchingDatabaseDigest
        )
        var workerExecution = makeGeometryWorkerExecutionArtifact(
            resolvedBudget: workerBudget,
            pairExecution: ColmapPairWorkerExecutionEvidence(
                attemptOrdinal: acceptedPairAttempt.artifact.attemptNumber,
                descriptorMatcher: acceptedPairAttempt.artifact.matcher,
                scheduledPairCount: acceptedPairAttempt.artifact.scheduledPairCount,
                pairListDigest: pairGraphEvidence.pairListDigest
            ),
            colmapRuntimeClosure: runtimeClosure
        )
        let mapperIndex = try XCTUnwrap(
            workerExecution.mappingAndRefinementInvocations.firstIndex {
                $0.command == .mapper
            }
        )
        var mapperExecution = try XCTUnwrap(
            workerExecution.mappingAndRefinementInvocations[mapperIndex]
                .mapperExecution
        )
        mapperExecution.matchingDatabaseDigest = matchingDatabaseDigest
        workerExecution.mappingAndRefinementInvocations[mapperIndex]
            .mapperExecution = mapperExecution
        _ = try GeometryWorkerExecutionArtifactStore.save(
            workerExecution,
            to: GeometryWorkerExecutionArtifactStore.canonicalURL(for: paths),
            expectedBudget: workerBudget,
            projectPaths: paths
        )
        let modelURL = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        try writeConditionedGeometryArtifactModel(at: modelURL, imageNames: imageNames)
        let conditioningAnalysis = try ColmapResidualAnalyzer.analyzeConditioning(
            modelDirectory: modelURL,
            maximumRayPairEvaluations:
                GeometryConditioningArtifact.defaultMaximumRayPairEvaluations
        )
        let residuals = conditioningAnalysis.residuals
        let modelHashes = try Dictionary(uniqueKeysWithValues: [
            "cameras.txt",
            "images.txt",
            "points3D.txt",
        ].map { name in
            (name, try GeometryArtifactStore.sha256(of: modelURL.appendingPathComponent(name)))
        })
        let modelClosureSHA256 = try XCTUnwrap(
            GeometryArtifactStore.modelClosureDigest(
                modelHashes,
                expectedNames: ["cameras.txt", "images.txt", "points3D.txt"]
            )
        )
        let featureEvidence = try ColmapFeatureEvidenceStore.load(
            from: paths.colmapFeatureEvidenceURL,
            projectPaths: paths
        )
        let artifact = GeometryArtifact(
            schemaVersion: GeometryArtifact.currentSchemaVersion,
            solverVersion: "colmap-test-fixture",
            runtimeVersion: "toolchain-test-fixture",
            modelVersion: "none",
            inputDigest: try GeometryArtifactStore.inputDigest(projectPaths: paths),
            selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
                orderedImageNames: imageNames,
                projectPaths: paths
            ),
            orderedImageNames: imageNames,
            orderedImageTimestamps: Array(repeating: nil, count: imageNames.count),
            sourceModelPath: "SfM/colmap/sparse/0",
            poseConvention: "world-to-camera",
            quaternionOrder: "wxyz",
            handedness: "right-handed",
            scaleType: "arbitrary-sim3",
            cameraModel: featureEvidence.cameraInitializationReceipt.cameraModel,
            cameraGrouping: try XCTUnwrap(metadata.resolvedRunPlan).cameraGrouping,
            cameraGroupingReceipt: featureEvidence.cameraGroupingReceipt,
            cameraInitializationReceipt: featureEvidence.cameraInitializationReceipt,
            featureDatabaseDigest: featureEvidence.featureDatabaseDigest,
            registeredViewCount: residuals.registeredViewCount,
            totalViewCount: imageNames.count,
            observationCount: residuals.observationCount,
            pointCount: residuals.pointCount,
            residualProvenance: residuals.provenance,
            medianPixelResidual: residuals.medianPixelResidual,
            p90PixelResidual: residuals.p90PixelResidual,
            conditioning: GeometryConditioningArtifact(
                sourceModelClosureSHA256: modelClosureSHA256,
                measurement: conditioningAnalysis.measurement
            ),
            timings: [
                PipelineStage.sfmMapping.rawValue: 1,
                "orientation_estimation_seconds": 0.001,
            ],
            peakMemoryBytes: 1,
            modelHashes: modelHashes,
            provenance: GeometryProvenance(
                toolchainVersion: "test-toolchain",
                solver: GeometryComponentProvenance(
                    identifier: "colmap",
                    version: "test",
                    revision: "test",
                    payloadSHA256: workerExecution.colmapRuntimeClosure.closureSHA256
                ),
                runtime: nil,
                model: nil
            ),
            workerExecution: workerExecution,
            pairGraph: pairGraphArtifact,
            mapping: MappingArtifact(
                modelCount: 1,
                largestModelRegisteredViewCount: residuals.registeredViewCount,
                secondLargestModelRegisteredViewCount: 0,
                unionRegisteredViewCount: residuals.registeredViewCount,
                attemptCount: 1,
                acceptedMappingAttemptOrdinal: 1,
                acceptedRefinementKind: .incrementalGlobal,
                acceptedRefinementInvocationCount: 1,
                incrementalCadence: IncrementalMappingCadenceArtifact(
                    localMaxRefinements: 2,
                    globalFramesRatio: 1.4,
                    globalPointsRatio: 1.4,
                    globalMaxRefinements: 5
                ),
                canonicalModelPublication: directTextPublication(modelHashes),
                fallbackReason: nil
            ),
            canonicalOrientation: .unresolved(
                openingViewDirection: CanonicalDirection(x: 0, y: 0, z: 1)
            )
        )
        try GeometryArtifactStore.persist(
            artifact,
            metadata: &metadata,
            paths: paths,
            measuredResiduals: residuals
        )
        try ProjectMetadataStore.savePreservingUserEditableFields(
            metadata,
            to: paths.metadataURL
        )
    }

    private func writeConditionedGeometryArtifactModel(
        at modelURL: URL,
        imageNames: [String]
    ) throws {
        precondition(imageNames.count >= 2)
        try FileManager.default.createDirectory(
            at: modelURL,
            withIntermediateDirectories: true
        )
        try "1 SIMPLE_RADIAL 640 480 500 320 240 0\n".write(
            to: modelURL.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )
        let points: [OrientationVector3] = (0..<25).map { index in
            let column = index % 5 - 2
            let row = index / 5 - 2
            return OrientationVector3(
                x: Double(column) * 0.75,
                y: Double(row) * 0.75,
                z: 12
            )
        }
        var tracks = Array(repeating: [String](), count: points.count)
        let imageRows = imageNames.enumerated().flatMap { offset, name -> [String] in
            let imageID = offset + 1
            let centerX = (Double(offset) - Double(imageNames.count - 1) / 2) * 2
            let observations = points.enumerated().map { pointIndex, point in
                let x = 500 * (point.x - centerX) / point.z + 320
                let y = 500 * point.y / point.z + 240
                tracks[pointIndex].append("\(imageID) \(pointIndex)")
                return "\(x) \(y) \(pointIndex + 1)"
            }.joined(separator: " ")
            return [
                "\(imageID) 1 0 0 0 \(-centerX) 0 0 1 \(name)",
                observations,
            ]
        }
        try (imageRows.joined(separator: "\n") + "\n").write(
            to: modelURL.appendingPathComponent("images.txt"),
            atomically: true,
            encoding: .utf8
        )
        let pointRows = points.enumerated().map { index, point in
            "\(index + 1) \(point.x) \(point.y) \(point.z) 128 128 128 0 "
                + tracks[index].joined(separator: " ")
        }
        try (pointRows.joined(separator: "\n") + "\n").write(
            to: modelURL.appendingPathComponent("points3D.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func persistPairGraphEvidenceFixture(
        paths: ProjectPaths,
        imageNames: [String]
    ) throws -> PairGraphEvidence {
        let plan = try ColmapPairPlan.exhaustive(imageNames: imageNames)
        let inspection = try ColmapPairGraphInspector(
            databaseURL: paths.colmapDatabaseURL
        ).inspect(
            schedule: ColmapPairSchedule(
                imageNames: imageNames,
                pairs: plan.pairs
            ),
            completion: .succeeded
        )
        let attempt = PairGraphAttemptEvidence(
            artifact: PairMatchingAttemptArtifact(
                attemptNumber: 1,
                matcher: .faiss,
                recoveryLevel: .normal,
                outcome: .completed,
                scheduledPairCount: inspection.scheduledPairCount,
                attemptedPairCount: inspection.attemptedPairCount,
                rawMatchedPairCount: inspection.rawMatchedPairCount,
                spatiallyVerifiedPairCount: inspection.spatiallyVerifiedPairCount,
                durationSeconds: 0.01
            ),
            scheduledPairs: plan.pairs
        )
        let evidence = PairGraphEvidence(
            selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
                orderedImageNames: imageNames,
                projectPaths: paths
            ),
            imageNames: imageNames,
            pairingPolicy: .unorderedRetrieval,
            attempts: [attempt],
            acceptedAttemptNumber: 1,
            acceptedInspection: inspection,
            matchingDurationSeconds: 0.01,
            fallbackReasons: []
        )
        try PairGraphEvidenceStore.save(
            evidence,
            to: paths.pairGraphEvidenceURL,
            projectPaths: paths
        )
        return evidence
    }

    private func writeCompletedColmapDatabase(paths: ProjectPaths) throws {
        try writeFeatureDatabase(for: [
            "--database_path", paths.colmapDatabaseURL.path,
            "--image_path", paths.framesSelectedURL.path,
        ])
        let imageNames = selectedImageNames(in: paths)
        let cameraGroupingReceipt = try ColmapCameraGroupingStore.normalize(
            databaseURL: paths.colmapDatabaseURL,
            selectedImages: imageNames.map {
                ColmapSelectedImageCameraEvidence(
                    imageName: $0,
                    sourceGroupID: "photos",
                    isVideo: false
                )
            },
            mode: .preserveExisting
        )
        try ColmapFeatureEvidenceStore.save(
            ColmapFeatureEvidence(
                selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
                    orderedImageNames: imageNames,
                    projectPaths: paths
                ),
                imageNames: imageNames,
                featureDatabaseDigest: try ColmapDatabaseDigester
                    .digests(at: paths.colmapDatabaseURL).feature,
                cameraGroupingReceipt: cameraGroupingReceipt,
                cameraInitializationReceipt: .automaticPerImageSimpleRadial
            ),
            to: paths.colmapFeatureEvidenceURL,
            projectPaths: paths
        )
        let plan = try ColmapPairPlan.exhaustive(imageNames: imageNames)
        let pairList = paths.colmapSeedURL.appendingPathComponent("fixture-pairs.txt")
        try plan.serializedData.write(to: pairList, options: .atomic)
        try writeVerifiedPairResults(for: [
            "--database_path", paths.colmapDatabaseURL.path,
            "--match_list_path", pairList.path,
        ])
    }

    private func writePartialMatchRows(at databaseURL: URL) throws {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "PipelineIntegrationTests", code: 1)
        }
        let sql = """
        INSERT INTO matches(pair_id, rows, cols, data) VALUES (2147483649, 1, 2, X'0000');
        INSERT INTO two_view_geometries(pair_id, rows, cols, data)
            VALUES (2147483649, 1, 2, X'0000');
        """
        var errorMessage: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? "sqlite error \(sqlite3_errcode(database))"
            sqlite3_free(errorMessage)
            throw NSError(
                domain: "PipelineIntegrationTests",
                code: Int(sqlite3_errcode(database)),
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
    }

    private func markMatchingAsInterrupted(paths: ProjectPaths) throws {
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        metadata.checkpoint = PipelineCheckpoint(
            stage: .sfmMatching,
            updatedAt: Date(timeIntervalSince1970: 2),
            progressFraction: 0.5,
            message: "Image matching interrupted",
            inputReceiptDigest: try RuntimeInputSnapshotLease.receiptDigest(
                metadata: metadata
            ),
            details: .sfmMatching(SfmMatchingCheckpoint(
                databasePath: try paths.projectRelativePath(
                    for: paths.colmapDatabaseURL
                ),
                expectedPairs: 1,
                processedPairs: 1
            ))
        )
        metadata.lastRunStartedAt = Date(timeIntervalSince1970: 1)
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
    }

    private func databaseRowCount(_ table: String, at databaseURL: URL) throws -> Int {
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else {
            throw NSError(domain: "PipelineIntegrationTests", code: 2)
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM \(table);", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw NSError(domain: "PipelineIntegrationTests", code: 3)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw NSError(domain: "PipelineIntegrationTests", code: 4)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func writeDa3RunArtifacts(
        for args: [String],
        imageName: String = "frame_000000.jpg",
        selectedModelSubdirectory: String? = nil
    ) throws {
        guard let manifestPath = value(for: "--manifest-out", in: args),
              let imagesPath = value(for: "--images", in: args),
              let out = value(for: "--out-sparse", in: args) else {
            return
        }

        let imagesURL = URL(fileURLWithPath: imagesPath, isDirectory: true)
        let imageNames = try FileManager.default.contentsOfDirectory(
            at: imagesURL,
            includingPropertiesForKeys: nil
        )
        .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
        .map(\.lastPathComponent)
        .sorted()

        let totalImages = imageNames.count
        let requestedWindowSize = Int(value(for: "--window-size", in: args) ?? "") ?? max(2, totalImages)
        let requestedWindowOverlap = Int(value(for: "--window-overlap", in: args) ?? "") ?? 0
        let effectiveWindowSize = max(2, min(totalImages, requestedWindowSize))
        let effectiveWindowOverlap = max(0, min(requestedWindowOverlap, effectiveWindowSize - 1))
        let inputOrdering = value(for: "--input-ordering", in: args) ?? "automatic"
        let windowIndices: [[Int]]
        if inputOrdering == "unordered", totalImages > effectiveWindowSize {
            let anchors = [0, 1, 2]
            windowIndices = [Array(0..<effectiveWindowSize)] + stride(
                from: effectiveWindowSize,
                to: totalImages,
                by: max(1, effectiveWindowSize - anchors.count)
            ).map { start in anchors + Array(start..<min(totalImages, start + effectiveWindowSize - anchors.count)) }
        } else {
            windowIndices = planWindows(
                imageCount: totalImages,
                windowSize: effectiveWindowSize,
                windowOverlap: effectiveWindowOverlap
            ).map { Array($0.0..<$0.1) }
        }

        let sharedCamera = args.contains("--shared-camera")
        let cameraType = value(for: "--camera-type", in: args) ?? "SIMPLE_RADIAL"
        try writeDa3PoseSeed(
            at: URL(fileURLWithPath: out),
            imageNames: imageNames.isEmpty ? [imageName] : imageNames,
            sharedCamera: sharedCamera,
            cameraModel: cameraType
        )

        let manifest = Da3CoverageManifest(
            mode: "seed_refine",
            requestedDevice: value(for: "--device", in: args) ?? "mps",
            selectedDevice: "mps",
            modelSubdirectory: selectedModelSubdirectory
                ?? value(for: "--model-subdir", in: args)
                ?? "DA3-BASE",
            processResolution: Int(value(for: "--process-res", in: args) ?? "") ?? 504,
            cameraType: cameraType,
            sharedCamera: sharedCamera,
            maxPoints: Int(value(for: "--max-points", in: args) ?? "") ?? 120_000,
            totalImages: totalImages,
            windowSize: effectiveWindowSize,
            windowOverlap: effectiveWindowOverlap,
            windows: windowIndices.map { indices in
                Da3CoverageManifest.Window(
                    start: indices.min() ?? 0,
                    end: (indices.max() ?? -1) + 1,
                    images: indices.map { imageNames[$0] },
                    indices: indices
                )
            },
            rawPointSampleCount: 8,
            fusedSparsePointCount: 4,
            finalObservationCount: nil,
            meanTrackLength: nil,
            registeredImageCount: totalImages,
            nativeColmapExport: false,
            exportStrategy: "aligned_pose_depth_seed",
            inputOrdering: inputOrdering == "automatic" ? "unordered" : inputOrdering,
            anchorImageNames: Array(imageNames.prefix(3)),
            alignmentEdgeCount: max(0, windowIndices.count - 1),
            maxAlignmentRMSE: 0.01,
            alignmentComplete: true
        )

        let data = try JSONEncoder().encode(manifest)
        try data.write(to: URL(fileURLWithPath: manifestPath), options: [.atomic])
    }

    private func writeDa3PoseSeed(
        at modelURL: URL,
        imageNames: [String],
        sharedCamera: Bool,
        cameraModel: String
    ) throws {
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        let cameraCount = sharedCamera ? 1 : imageNames.count
        let camerasText = try (1...cameraCount)
            .map { try sparseCameraRecord(cameraID: $0, cameraModel: cameraModel) }
            .joined(separator: "\n") + "\n"
        try camerasText
            .write(to: modelURL.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
        let imagesText = imageNames.enumerated()
            .map { offset, name in
                let cameraID = sharedCamera ? 1 : offset + 1
                return "\(offset + 1) 1 0 0 0 0 0 0 \(cameraID) \(name)\n"
            }
            .joined(separator: "\n")
        try (imagesText + "\n").write(
            to: modelURL.appendingPathComponent("images.txt"),
            atomically: true,
            encoding: .utf8
        )
        try "# Number of points: 0\n".write(
            to: modelURL.appendingPathComponent("points3D.txt"),
            atomically: true,
            encoding: .utf8
        )
        try """
        # learned points
        1 0 0 1 255 0 0 -1.0
        2 1 0 1 0 255 0 -1.0
        3 0 1 1 0 0 255 -1.0
        4 1 1 1 255 255 255 -1.0

        """.write(
            to: modelURL.appendingPathComponent("learned_points3D.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func makeSparseModelHighResidual(at modelURL: URL) throws {
        let imagesURL = modelURL.appendingPathComponent("images.txt")
        let lines = try String(contentsOf: imagesURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
        var expectsObservations = false
        let corrupted = try lines.map { line -> String in
            guard !line.hasPrefix("#"), !line.isEmpty else {
                return String(line)
            }
            defer { expectsObservations.toggle() }
            guard expectsObservations else {
                return String(line)
            }
            var fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count.isMultiple(of: 3) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            for index in stride(from: 0, to: fields.count, by: 3) {
                guard let x = Double(fields[index]) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                fields[index] = String(x + 4)
            }
            return fields.joined(separator: " ")
        }.joined(separator: "\n")
        try corrupted.write(to: imagesURL, atomically: true, encoding: .utf8)
    }

    private func writeDa3SparseModel(
        at modelURL: URL,
        imageNames: [String],
        pointCount: Int,
        cameraModel: String = "SIMPLE_RADIAL"
    ) throws {
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try (sparseCameraRecord(cameraID: 1, cameraModel: cameraModel) + "\n")
            .write(to: modelURL.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)

        let columnCount = max(2, Int(ceil(sqrt(Double(pointCount)))))
        let rowCount = max(2, Int(ceil(Double(pointCount) / Double(columnCount))))
        let pointPositions = (0..<pointCount).map { pointOffset in
            (
                x: Double(pointOffset % columnCount) - Double(columnCount - 1) / 2,
                y: Double(pointOffset / columnCount) - Double(rowCount - 1) / 2,
                z: 12.0
            )
        }
        var tracks = Array(repeating: [String](), count: pointCount)
        var imagesText = "# Image list with two lines per image:\n"
        for (offset, imageName) in imageNames.enumerated() {
            let imageID = offset + 1
            let centerX = Double(offset) * 0.25
            imagesText += "\(imageID) 1 0 0 0 \(-centerX) 0 0 1 \(imageName)\n"
            let observations = pointPositions.enumerated()
                .map { pointOffset, point in
                    tracks[pointOffset].append("\(imageID) \(pointOffset)")
                    let x = 500 * (point.x - centerX) / point.z + 320
                    let y = 500 * point.y / point.z + 240
                    return "\(x) \(y) \(pointOffset + 1)"
                }
                .joined(separator: " ")
            imagesText += observations + "\n"
        }
        try imagesText.write(to: modelURL.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)

        let points = pointPositions.enumerated()
            .map { pointOffset, point in
                "\(pointOffset + 1) \(point.x) \(point.y) \(point.z) 128 128 128 1.0 "
                    + tracks[pointOffset].joined(separator: " ")
            }
            .joined(separator: "\n")
        try (points + "\n").write(to: modelURL.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)
    }

    private func sparseCameraRecord(cameraID: Int, cameraModel: String) throws -> String {
        let parameters: String
        switch cameraModel {
        case "SIMPLE_PINHOLE":
            parameters = "500 320 240"
        case "PINHOLE":
            parameters = "500 500 320 240"
        case "SIMPLE_RADIAL":
            parameters = "500 320 240 0"
        case "RADIAL":
            parameters = "500 320 240 0 0"
        case "OPENCV", "OPENCV_FISHEYE":
            parameters = "500 500 320 240 0 0 0 0"
        default:
            throw NSError(domain: "PipelineIntegrationTests", code: 46)
        }
        return "\(cameraID) \(cameraModel) 640 480 \(parameters)"
    }

    private func planWindows(imageCount: Int, windowSize: Int, windowOverlap: Int) -> [(Int, Int)] {
        guard imageCount > 0 else { return [] }
        let size = max(2, min(windowSize, imageCount))
        let overlap = max(0, min(windowOverlap, size - 1))
        let stride = max(1, size - overlap)
        if imageCount <= size {
            return [(0, imageCount)]
        }

        var windows: [(Int, Int)] = []
        var start = 0
        while start < imageCount {
            let end = min(start + size, imageCount)
            if windows.last?.1 == end {
                break
            }
            windows.append((start, end))
            if end == imageCount {
                break
            }
            start += stride
        }
        return windows
    }

    private func value(for flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private func makeToolchain(
        root: URL,
        createDa3Files: Bool = false,
        createMsplatFile: Bool = false
    ) throws -> ToolchainPaths {
        let fm = FileManager.default
        let toolchainRoot = root.appendingPathComponent("Toolchain", isDirectory: true)
        let bin = toolchainRoot.appendingPathComponent("bin", isDirectory: true)
        let lib = toolchainRoot.appendingPathComponent("lib", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: lib, withIntermediateDirectories: true)
        try Data("fixture OpenMP runtime".utf8).write(
            to: lib.appendingPathComponent("libomp.dylib")
        )

        func writeStub(_ name: String) throws -> URL {
            let url = bin.appendingPathComponent(name)
            let stub = [
                "#!/usr/bin/env bash",
                "exit 0",
                ""
            ].joined(separator: "\n")
            try stub.write(to: url, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        }

        let colmap = try writeStub("colmap")
        let colmapProvenance = toolchainRoot.appendingPathComponent("provenance/colmap.json")
        try fm.createDirectory(
            at: colmapProvenance.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let colmapExecutableSHA256 = try GeometryArtifactStore.sha256(of: colmap)
        try """
        {
          "toolchain_name": "colmap",
          "source_version": "4.1.1",
          "source_commit": "a0d785fba74b2664f31edc4a29026a8b27c00f67",
          "executable_sha256": "\(colmapExecutableSHA256)"
        }
        """.write(to: colmapProvenance, atomically: true, encoding: .utf8)
        let msplat = createMsplatFile ? try writeStub("easysplat-train") : bin.appendingPathComponent("easysplat-train")

        let da3 = try TestToolchains.da3Toolchain(root: toolchainRoot, createFiles: createDa3Files)
        return ToolchainPaths(
            root: toolchainRoot,
            colmap: colmap,
            msplat: msplat,
            da3: da3
        )
    }

    private func makeMsplatIdentitySparseFixture(
        from sourceSparse: URL,
        under root: URL,
        canonicalOrientation: CanonicalOrientationArtifact
    ) throws -> URL {
        let sparse = root
            .appendingPathComponent("identity-fixtures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            try FileManager.default.copyItem(
                at: sourceSparse.appendingPathComponent(name),
                to: sparse.appendingPathComponent(name)
            )
        }
        try MsplatOrientationOverlay.write(
            canonicalOrientation,
            to: sparse
        )
        return sparse
    }

    private func writeMinimalColmapBinaryModel(
        at directory: URL,
        imageNames: [String]
    ) throws {
        precondition(!imageNames.isEmpty)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        var cameras = Data()
        appendLittleEndian(UInt64(1), to: &cameras)
        appendLittleEndian(UInt32(1), to: &cameras)
        appendLittleEndian(Int32(0), to: &cameras) // SIMPLE_PINHOLE
        appendLittleEndian(UInt64(640), to: &cameras)
        appendLittleEndian(UInt64(480), to: &cameras)
        for parameter in [500.0, 320.0, 240.0] {
            appendLittleEndian(parameter.bitPattern, to: &cameras)
        }

        var images = Data()
        appendLittleEndian(UInt64(imageNames.count), to: &images)
        for (offset, name) in imageNames.enumerated() {
            appendLittleEndian(UInt32(offset + 1), to: &images)
            for value in [1.0, 0, 0, 0, 0, 0, 0] {
                appendLittleEndian(value.bitPattern, to: &images)
            }
            appendLittleEndian(UInt32(1), to: &images)
            images.append(contentsOf: name.utf8)
            images.append(0)
            appendLittleEndian(UInt64(1), to: &images)
            appendLittleEndian(320.0.bitPattern, to: &images)
            appendLittleEndian(240.0.bitPattern, to: &images)
            appendLittleEndian(UInt64(1), to: &images)
        }

        var points = Data()
        appendLittleEndian(UInt64(1), to: &points)
        appendLittleEndian(UInt64(1), to: &points)
        for coordinate in [0.0, 0.0, 1.0] {
            appendLittleEndian(coordinate.bitPattern, to: &points)
        }
        points.append(contentsOf: [128, 128, 128])
        appendLittleEndian(0.0.bitPattern, to: &points)
        appendLittleEndian(UInt64(imageNames.count), to: &points)
        for offset in imageNames.indices {
            appendLittleEndian(UInt32(offset + 1), to: &points)
            appendLittleEndian(UInt32(0), to: &points)
        }

        try cameras.write(
            to: directory.appendingPathComponent("cameras.bin"),
            options: .atomic
        )
        try images.write(
            to: directory.appendingPathComponent("images.bin"),
            options: .atomic
        )
        try points.write(
            to: directory.appendingPathComponent("points3D.bin"),
            options: .atomic
        )
    }

    private func appendLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func makeTempRoot() -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temp)
        }
        return temp
    }
}

private final class PhotoAdmissionPathProbe {
    private(set) var preflightCount = 0
    private(set) var adoptionCount = 0

    func recordPreflight(_ prepared: PreparedPhotoInput) {
        preflightCount += 1
        XCTAssertFalse(prepared.photos.isEmpty)
    }

    func recordAdoption(_ adoption: ProjectInputAdoption) {
        adoptionCount += 1
        XCTAssertNotNil(adoption.photoInputReceipts)
        XCTAssertNotNil(adoption.photoSelectionReceipt)
    }
}

private final class RunStartMarkerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var observed = false

    var wasObserved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return observed
    }

    func record(observed value: Bool) {
        guard value else { return }
        lock.lock()
        observed = true
        lock.unlock()
    }
}

private final class CancellationOnSfmRunner: @unchecked Sendable, SubprocessRunning {
    private let cancelPath: String
    private let lock = NSLock()
    private var recordedCalls: [(String, [String])] = []

    init(cancelPath: String) {
        self.cancelPath = cancelPath
    }

    var calls: [(String, [String])] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    func run(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        removingEnvironmentKeys: Set<String>,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) throws -> SubprocessResult {
        try execute(launchPath, arguments)
    }

    func runAsync(
        _ launchPath: String,
        _ arguments: [String],
        currentDirectory: URL?,
        environment: [String: String],
        removingEnvironmentKeys: Set<String>,
        onStdout: @escaping @Sendable (String) -> Void,
        onStderr: @escaping @Sendable (String) -> Void
    ) async throws -> SubprocessResult {
        try execute(launchPath, arguments)
    }

    private func execute(_ launchPath: String, _ arguments: [String]) throws -> SubprocessResult {
        lock.lock()
        recordedCalls.append((launchPath, arguments))
        lock.unlock()

        if launchPath == cancelPath && arguments.starts(with: ["--images"]) {
            throw CancellationError()
        }

        return SubprocessResult(exitCode: 0, terminationReason: .exit, stdout: "", stderr: "")
    }
}

private final class PipelineEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PipelineEvent] = []

    func append(_ event: PipelineEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func stageLog(containing fragment: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return events.compactMap { event -> String? in
            guard case let .stageLog(_, line, _) = event, line.contains(fragment) else { return nil }
            return line
        }.first
    }

    func progressFractions(for stage: PipelineStage) -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        return events.compactMap { event in
            guard case let .stageProgress(eventStage, fraction, _) = event,
                  eventStage == stage else {
                return nil
            }
            return fraction
        }
    }

    func didStart(_ stage: PipelineStage) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return events.contains { event in
            guard case .stageStarted(let eventStage) = event else { return false }
            return eventStage == stage
        }
    }
}

private final class AtomicInputSwapProbe: @unchecked Sendable {
    private let replacement: URL
    private let destination: URL
    private let lock = NSLock()
    private var swapped = false
    private var capturedError: Error?

    init(replacement: URL, destination: URL) {
        self.replacement = replacement
        self.destination = destination
    }

    var didSwap: Bool {
        lock.withLock { swapped }
    }

    var error: Error? {
        lock.withLock { capturedError }
    }

    func observe(_ event: PipelineEvent, at stage: PipelineStage) {
        guard case .stageStarted(let eventStage) = event,
              eventStage == stage else {
            return
        }
        lock.withLock {
            guard !swapped, capturedError == nil else { return }
            guard Darwin.rename(replacement.path, destination.path) == 0 else {
                capturedError = NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno)
                )
                return
            }
            swapped = true
        }
    }
}

private final class InputReceiptCheckpointProbe: @unchecked Sendable {
    private let metadataURL: URL
    private let stage: PipelineStage
    private let lock = NSLock()
    private var capturedDigest: String?
    private var capturedError: Error?

    init(metadataURL: URL, stage: PipelineStage) {
        self.metadataURL = metadataURL
        self.stage = stage
    }

    var inputReceiptDigest: String? {
        lock.withLock { capturedDigest }
    }

    var error: Error? {
        lock.withLock { capturedError }
    }

    func observe(_ event: PipelineEvent) {
        guard case .stageProgress(let eventStage, _, _) = event,
              eventStage == stage else {
            return
        }
        lock.withLock {
            guard capturedDigest == nil, capturedError == nil else { return }
            do {
                capturedDigest = try ProjectMetadataStore.load(from: metadataURL)
                    .checkpoint?
                    .inputReceiptDigest
            } catch {
                capturedError = error
            }
        }
    }
}

#endif
