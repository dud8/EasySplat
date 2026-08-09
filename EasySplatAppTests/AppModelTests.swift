#if canImport(XCTest)
import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import EasySplatApp
@testable import EasySplatCore
@testable import EasySplatReleaseVerifierCore

func makeAppTestPhotoAnalysisEvidence(sourceSHA256: String) -> PhotoAnalysisEvidence {
    PhotoAnalysisEvidence(
        sourceSHA256: sourceSHA256,
        spatialDescriptor: [UInt8](repeating: 128, count: 64),
        qualityBucket: 128,
        dHash: 0,
        proxyPixelWidth: 256,
        proxyPixelHeight: 192,
        proxyPixelSHA256: String(repeating: "f", count: 64),
        analysisRecipeVersion: PhotoAnalysisEvidence.currentRecipeVersion,
        analysisRecipeSHA256: PhotoAnalysisEvidence.currentRecipeSHA256
    )
}

func makeAppTestTrainingResourceAdmission(
    resourcePolicy: ResourcePolicy = .automatic
) -> TrainingResourceAdmission {
    let gibibyte: UInt64 = 1_073_741_824
    let pageSize: UInt64 = 16_384
    let available = 56 * gibibyte
    let clock = TrainingResourceClockEvidence(
        wallClock: Date(timeIntervalSince1970: 1_721_234_567),
        monotonicTicks: 123_456_789,
        machTimebaseNumerator: 125,
        machTimebaseDenominator: 3,
        bootTimeSeconds: 1_721_200_000,
        bootTimeMicroseconds: 123_456
    )
    let observation = TrainingResourceObservation(
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
    return try! TrainingMemoryBudget.admit(
        observation: observation,
        resourcePolicy: resourcePolicy,
        freshnessReference: clock
    )
}

private extension VideoInputAnalysisEvidence {
    static let fixture = VideoInputAnalysisEvidence(
        trackID: 1,
        pixelWidth: 64,
        pixelHeight: 48,
        durationSeconds: 1,
        nominalFrameRate: 30,
        isHDR: false,
        decodedFrameCount: 3,
        preferredTransform: .identity
    )
}

@MainActor
final class AppModelTests: XCTestCase {
    private let standardHardwareProfile = HardwareProfile(
        memoryGB: 48,
        cpuCount: 16,
        gpuWorkingSetGB: 36
    )

    func testRequestedRunOptionsUseProfessionalDefaults() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: base,
            hardwareProfile: standardHardwareProfile
        ) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }

        XCTAssertEqual(model.requestedRunOptions, RequestedRunOptions())
        XCTAssertEqual(model.requestedRunOptions.capturePath, .automatic)
        XCTAssertEqual(model.requestedRunOptions.detailProfile, .balanced)
    }

    func testStartProjectTransitionsToViewer() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let mockToolchain = MockToolchainManager()
        let model = AppModel(
            toolchainManager: mockToolchain,
            projectBaseURL: tempBase,
            videoInputPreflight: passingVideoPreflight()
        ) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        model.addInputs(urls: [input])
        model.startFromPendingSelection()

        try await waitForViewState(model: model, state: .viewer)

        XCTAssertEqual(model.viewState, .viewer, model.errorDetails ?? model.lastError ?? "No failure detail")
        XCTAssertFalse(model.isRunActive)
        XCTAssertNotNil(model.currentProjectURL)
        XCTAssertNotNil(model.outputPlyURL)
        XCTAssertTrue(model.pendingVideoURLs.isEmpty)
        XCTAssertTrue(model.pendingPhotoURLs.isEmpty)
        guard let projectURL = model.currentProjectURL else {
            XCTFail("Missing project URL")
            return
        }
        let summary = model.projectSummaries.first {
            ProjectSummary.hasSameLocation($0.url, projectURL)
        }
        XCTAssertEqual(summary?.status, .ready)
        XCTAssertEqual(summary?.isActive, false)
        let metadataURL = projectURL.appendingPathComponent("project.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
    }

    func testStartFromPendingSelectionPreservesMonotonicPreparationBoundaryAcrossTaskHandoff() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let wallClockStart = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = LockedRunTimingSamples([
            .init(wallClock: wallClockStart, monotonicSeconds: 100),
            .init(
                wallClock: wallClockStart.addingTimeInterval(-3_600),
                monotonicSeconds: 102
            ),
            .init(
                wallClock: wallClockStart.addingTimeInterval(7_200),
                monotonicSeconds: 109
            ),
            .init(wallClock: wallClockStart, monotonicSeconds: 999),
        ])
        let boundary = RunTimingBoundary.capture(sample: samples.next)
        let publicationID = UUID(
            uuidString: "11111111-2222-4333-8444-555555555555"
        )!
        var capturedConfig: PipelineRunner.PipelineConfig?
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            videoInputPreflight: passingVideoPreflight()
        ) { projectURL, config in
            capturedConfig = config
            return PublishedResultMockPipelineRunner(
                projectURL: projectURL,
                config: config,
                publicationID: publicationID
            )
        }
        model.addInputs(urls: [input])

        model.startFromPendingSelection(timingBoundary: boundary)
        try await waitForViewState(model: model, state: .viewer)

        let config = try XCTUnwrap(capturedConfig)
        XCTAssertEqual(config.prePipelineStartedAt, wallClockStart)
        XCTAssertEqual(config.prePipelineDurationSeconds, 2, accuracy: 1e-12)
        XCTAssertEqual(samples.readCount, 2)

        let projectURL = try XCTUnwrap(model.currentProjectURL)
        let outputURL = try XCTUnwrap(model.outputPlyURL)
        let paths = ProjectPaths(root: projectURL)
        XCTAssertEqual(
            model.pendingResultViewerTiming?.expectedPublicationID,
            publicationID
        )
        let preparedReceipt = try PublishedSplatReceiptStore.load(
            projectPaths: paths
        )
        let preparedMetadata = try ProjectMetadataStore.load(
            from: paths.metadataURL
        )
        let preparedStageTimings = try XCTUnwrap(
            preparedMetadata.stageTimings
        )
        XCTAssertEqual(preparedStageTimings.map(\.stage), [.trainSplat])
        XCTAssertEqual(preparedReceipt.publicationID, publicationID)
        XCTAssertNil(preparedReceipt.presentation.createToViewerReadySeconds)
        model.resultViewerDidBecomeReady(
            projectURL: projectURL.appendingPathComponent("stale.easysplatproj"),
            outputURL: outputURL
        )
        XCTAssertEqual(samples.readCount, 2)
        model.resultViewerDidBecomeReady(
            projectURL: projectURL,
            outputURL: outputURL.appendingPathComponent("stale.ply")
        )
        XCTAssertEqual(samples.readCount, 2)

        model.resultViewerDidBecomeReady(projectURL: projectURL, outputURL: outputURL)
        let recordedReceipt = try await waitForPublishedViewerTiming(
            paths: paths,
            expectedSeconds: 9
        )
        let recorded = try await waitForPersistedViewerTiming(
            paths: paths,
            expectedSeconds: 9
        )
        XCTAssertEqual(try XCTUnwrap(recorded.createToViewerReadySeconds), 9, accuracy: 1e-12)
        XCTAssertEqual(recordedReceipt.publicationID, publicationID)
        XCTAssertEqual(
            try XCTUnwrap(
                recordedReceipt.presentation.createToViewerReadySeconds
            ),
            9,
            accuracy: 1e-12
        )
        XCTAssertEqual(recorded.stageTimings, preparedStageTimings)
        XCTAssertEqual(samples.readCount, 3)

        model.resultViewerDidBecomeReady(projectURL: projectURL, outputURL: outputURL)
        let unchanged = try ProjectMetadataStore.load(
            from: ProjectPaths(root: projectURL).metadataURL
        )
        XCTAssertEqual(try XCTUnwrap(unchanged.createToViewerReadySeconds), 9, accuracy: 1e-12)
        XCTAssertEqual(unchanged.stageTimings, preparedStageTimings)
        XCTAssertEqual(samples.readCount, 3)
    }

    func testViewerTimingRetriesMetadataAfterReceiptCommitWithoutChangingReceipt() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent(
            "Viewer Timing Retry.easysplatproj",
            isDirectory: true
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()

        var metadata = ProjectMetadata(
            title: "Viewer Timing Retry",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced
            ),
            state: PipelineState(stage: .done, lastError: nil)
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: standardHardwareProfile,
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let publicationID = UUID(
            uuidString: "c9a82f1d-9e86-4d57-a99a-f67ded2fe1d5"
        )!
        let sourceURL = paths.trainingURL.appendingPathComponent("current-result.ply")
        try writeMinimalPly(at: sourceURL)
        let result = try publishAppTestResult(
            sourceURL: sourceURL,
            paths: paths,
            metadata: metadata,
            publicationID: publicationID
        )
        let samples = LockedRunTimingSamples([
            .init(
                wallClock: Date(timeIntervalSince1970: 1_700_000_000),
                monotonicSeconds: 20
            ),
            .init(
                wallClock: Date(timeIntervalSince1970: 1_700_000_007),
                monotonicSeconds: 27
            ),
        ])
        let updater = ViewerTimingMetadataUpdateProbe()
        let receiptUpdater = ViewerTimingReceiptUpdateProbe()
        let plyValidationCounter = LockedCallCounter()
        var pairOperations = PublishedResultPairOperations.system()
        pairOperations.willValidatePly = { _ in
            plyValidationCounter.record()
        }
        let model = AppModel(
            projectBaseURL: tempBase,
            projectMetadataUpdater: updater.update,
            resultViewerTimingReceiptUpdater: receiptUpdater.update,
            resultViewerTimingPairOperations: pairOperations
        )
        model.currentProjectURL = projectURL
        model.outputPlyURL = result.outputURL
        model.viewState = .viewer
        model.prepareResultViewerTiming(
            projectID: metadata.id,
            projectURL: projectURL,
            outputURL: result.outputURL,
            expectedPublicationID: publicationID,
            boundary: .capture(sample: samples.next)
        )

        model.resultViewerDidBecomeReady(
            projectURL: projectURL,
            outputURL: result.outputURL
        )
        let firstReceipt = try await waitForPublishedViewerTiming(
            paths: paths,
            expectedSeconds: 7
        )
        XCTAssertEqual(firstReceipt.publicationID, publicationID)
        XCTAssertEqual(
            firstReceipt.presentation.createToViewerReadySeconds,
            7
        )
        let persisted = try await waitForPersistedViewerTiming(
            paths: paths,
            expectedSeconds: 7
        )
        let retriedReceipt = try PublishedSplatReceiptStore.load(projectPaths: paths)

        XCTAssertEqual(updater.attemptCount, 2)
        XCTAssertEqual(
            receiptUpdater.attemptCount,
            1,
            "A metadata retry must not rewrite the receipt."
        )
        XCTAssertEqual(
            plyValidationCounter.count,
            1,
            "The receipt update and both metadata attempts must share one PLY validation."
        )
        XCTAssertEqual(persisted.createToViewerReadySeconds, 7)
        XCTAssertEqual(retriedReceipt.publicationID, publicationID)
        XCTAssertEqual(
            retriedReceipt.presentation.createToViewerReadySeconds,
            7
        )
        try await waitForViewerTimingTaskToFinish(model: model)
        XCTAssertNil(model.pendingResultViewerTiming)
        XCTAssertEqual(samples.readCount, 2)
    }

    func testViewerTimingReceiptAndMetadataShareOneContinuouslyHeldRunLease() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent(
            "Viewer Timing Lease.easysplatproj",
            isDirectory: true
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        var metadata = ProjectMetadata(
            title: "Viewer Timing Lease",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced
            ),
            state: PipelineState(stage: .done, lastError: nil)
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: standardHardwareProfile,
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let publicationID = UUID()
        let sourceURL = paths.trainingURL.appendingPathComponent("lease-result.ply")
        try writeMinimalPly(at: sourceURL)
        let result = try publishAppTestResult(
            sourceURL: sourceURL,
            paths: paths,
            metadata: metadata,
            publicationID: publicationID
        )
        let leaseProbe = ViewerTimingRunLeaseProbe(projectURL: projectURL)
        let model = AppModel(
            projectBaseURL: tempBase,
            projectMetadataUpdater: { descriptor, mutation in
                leaseProbe.observeMetadataUpdate()
                return try ProjectMetadataStore.update(
                    atProjectRootDescriptor: descriptor,
                    mutation
                )
            },
            projectRunLeaseOwnerAcquirer: leaseProbe.acquire,
            resultViewerTimingReceiptUpdater: {
                seconds,
                expectedPublicationID,
                expectedGeneration,
                projectPaths,
                projectRootDescriptor,
                operations,
                shouldCancel in
                leaseProbe.observeReceiptUpdate()
                return try PublishedResultPairStore.recordFirstViewerReadyTiming(
                    seconds,
                    expectedPublicationID: expectedPublicationID,
                    expectedGeneration: expectedGeneration,
                    projectPaths: projectPaths,
                    projectRootDescriptor: projectRootDescriptor,
                    operations: operations,
                    shouldCancel: shouldCancel
                )
            }
        )
        model.currentProjectURL = projectURL
        model.outputPlyURL = result.outputURL
        model.viewState = .viewer
        model.prepareResultViewerTiming(
            projectID: metadata.id,
            projectURL: projectURL,
            outputURL: result.outputURL,
            expectedPublicationID: publicationID,
            boundary: .capture(sample: LockedRunTimingSamples([
                .init(wallClock: Date(), monotonicSeconds: 10),
                .init(wallClock: Date(), monotonicSeconds: 13),
            ]).next)
        )

        model.resultViewerDidBecomeReady(
            projectURL: projectURL,
            outputURL: result.outputURL
        )
        _ = try await waitForPersistedViewerTiming(
            paths: paths,
            expectedSeconds: 3
        )

        XCTAssertEqual(leaseProbe.acquireCount, 1)
        XCTAssertTrue(leaseProbe.receiptObservedHeldLease)
        XCTAssertTrue(leaseProbe.metadataObservedHeldLease)
    }

    func testViewerTimingRootSwapBeforePairOpenMutatesNeitherProjectRoot() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent(
            "Viewer Timing Root A.easysplatproj",
            isDirectory: true
        )
        let replacementURL = tempBase.appendingPathComponent(
            "Viewer Timing Root B.easysplatproj",
            isDirectory: true
        )
        let parkedOriginalURL = tempBase.appendingPathComponent(
            "Viewer Timing Root A Parked.easysplatproj",
            isDirectory: true
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        var metadata = ProjectMetadata(
            title: "Viewer Timing Root Swap",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced
            ),
            state: PipelineState(stage: .done, lastError: nil)
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: standardHardwareProfile,
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let publicationID = UUID()
        let sourceURL = paths.trainingURL.appendingPathComponent("root-swap.ply")
        try writeMinimalPly(at: sourceURL)
        let result = try publishAppTestResult(
            sourceURL: sourceURL,
            paths: paths,
            metadata: metadata,
            publicationID: publicationID
        )
        try FileManager.default.copyItem(at: projectURL, to: replacementURL)
        let originalMetadata = try Data(contentsOf: paths.metadataURL)
        let originalReceipt = try Data(contentsOf: paths.outputSplatReceiptURL)
        let replacementPaths = ProjectPaths(root: replacementURL)
        let replacementMetadata = try Data(contentsOf: replacementPaths.metadataURL)
        let replacementReceipt = try Data(
            contentsOf: replacementPaths.outputSplatReceiptURL
        )
        let swapProbe = ViewerTimingRootSwapProbe(
            canonicalURL: projectURL,
            replacementURL: replacementURL,
            parkedOriginalURL: parkedOriginalURL
        )
        let plyValidationCounter = LockedCallCounter()
        var pairOperations = PublishedResultPairOperations.system()
        pairOperations.willOpenProjectRoot = swapProbe.swapBeforeOpen
        pairOperations.willValidatePly = { _ in
            plyValidationCounter.record()
        }
        let model = AppModel(
            projectBaseURL: tempBase,
            resultViewerTimingPairOperations: pairOperations
        )
        model.currentProjectURL = projectURL
        model.outputPlyURL = result.outputURL
        model.viewState = .viewer
        let samples = LockedRunTimingSamples([
            .init(wallClock: Date(), monotonicSeconds: 5),
            .init(wallClock: Date(), monotonicSeconds: 9),
        ])
        model.prepareResultViewerTiming(
            projectID: metadata.id,
            projectURL: projectURL,
            outputURL: result.outputURL,
            expectedPublicationID: publicationID,
            boundary: .capture(sample: samples.next)
        )

        model.resultViewerDidBecomeReady(
            projectURL: projectURL,
            outputURL: result.outputURL
        )
        try await waitForViewerTimingTaskToFinish(model: model)

        let parkedPaths = ProjectPaths(root: parkedOriginalURL)
        let canonicalReplacementPaths = ProjectPaths(root: projectURL)
        XCTAssertEqual(
            try Data(contentsOf: parkedPaths.metadataURL),
            originalMetadata
        )
        XCTAssertEqual(
            try Data(contentsOf: parkedPaths.outputSplatReceiptURL),
            originalReceipt
        )
        XCTAssertEqual(
            try Data(contentsOf: canonicalReplacementPaths.metadataURL),
            replacementMetadata
        )
        XCTAssertEqual(
            try Data(contentsOf: canonicalReplacementPaths.outputSplatReceiptURL),
            replacementReceipt
        )
        XCTAssertNil(
            try ProjectMetadataStore.load(from: parkedPaths.metadataURL)
                .createToViewerReadySeconds
        )
        XCTAssertNil(
            try ProjectMetadataStore.load(from: canonicalReplacementPaths.metadataURL)
                .createToViewerReadySeconds
        )
        XCTAssertEqual(swapProbe.attemptCount, 1)
        XCTAssertEqual(
            plyValidationCounter.count,
            0,
            "A replaced pathname must be rejected before either root's PLY is opened."
        )
        XCTAssertNil(model.pendingResultViewerTiming)
    }

    func testViewerTimingRetriesInitialMetadataReadWithoutSecondRendererEvent() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent(
            "Viewer Timing Read Retry.easysplatproj",
            isDirectory: true
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()

        var metadata = ProjectMetadata(
            title: "Viewer Timing Read Retry",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced
            ),
            state: PipelineState(stage: .done, lastError: nil)
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: standardHardwareProfile,
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let publicationID = UUID(
            uuidString: "9f2f3f12-a80c-4f10-b140-187b37d47d8c"
        )!
        let sourceURL = paths.trainingURL.appendingPathComponent("result.ply")
        try writeMinimalPly(at: sourceURL)
        let result = try publishAppTestResult(
            sourceURL: sourceURL,
            paths: paths,
            metadata: metadata,
            publicationID: publicationID
        )
        let samples = LockedRunTimingSamples([
            .init(
                wallClock: Date(timeIntervalSince1970: 1_700_000_000),
                monotonicSeconds: 10
            ),
            .init(
                wallClock: Date(timeIntervalSince1970: 1_700_000_005),
                monotonicSeconds: 15
            ),
        ])
        let metadataLoader = ViewerTimingMetadataLoadProbe(
            failuresBeforeSuccess: 1
        )
        let receiptUpdater = ViewerTimingReceiptUpdateProbe()
        let model = AppModel(
            projectBaseURL: tempBase,
            projectMetadataDescriptorLoader: metadataLoader.load,
            resultViewerTimingReceiptUpdater: receiptUpdater.update
        )
        model.currentProjectURL = projectURL
        model.outputPlyURL = result.outputURL
        model.viewState = .viewer
        model.prepareResultViewerTiming(
            projectID: metadata.id,
            projectURL: projectURL,
            outputURL: result.outputURL,
            expectedPublicationID: publicationID,
            boundary: .capture(sample: samples.next)
        )

        model.resultViewerDidBecomeReady(
            projectURL: projectURL,
            outputURL: result.outputURL
        )

        let persisted = try await waitForPersistedViewerTiming(
            paths: paths,
            expectedSeconds: 5
        )
        XCTAssertEqual(persisted.createToViewerReadySeconds, 5)
        XCTAssertEqual(metadataLoader.attemptCount, 2)
        XCTAssertEqual(receiptUpdater.attemptCount, 1)
        XCTAssertEqual(samples.readCount, 2)
        try await waitForViewerTimingTaskToFinish(model: model)
        XCTAssertNil(model.pendingResultViewerTiming)
    }

    func testViewerTimingDoesNotRepublishReceiptAfterMetadataRetriesFail() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent(
            "Viewer Timing Exhausted Retry.easysplatproj",
            isDirectory: true
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()

        var metadata = ProjectMetadata(
            title: "Viewer Timing Exhausted Retry",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced
            ),
            state: PipelineState(stage: .done, lastError: nil)
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: standardHardwareProfile,
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let publicationID = UUID(
            uuidString: "b7e22256-c0db-4bca-bc89-4c0efb56d418"
        )!
        let sourceURL = paths.trainingURL.appendingPathComponent("result.ply")
        try writeMinimalPly(at: sourceURL)
        let result = try publishAppTestResult(
            sourceURL: sourceURL,
            paths: paths,
            metadata: metadata,
            publicationID: publicationID
        )
        let metadataUpdater = AlwaysFailingViewerTimingMetadataUpdateProbe()
        let receiptUpdater = ViewerTimingReceiptUpdateProbe()
        let plyValidationCounter = LockedCallCounter()
        var pairOperations = PublishedResultPairOperations.system()
        pairOperations.willValidatePly = { _ in
            plyValidationCounter.record()
        }
        let samples = LockedRunTimingSamples([
            .init(
                wallClock: Date(timeIntervalSince1970: 1_700_000_000),
                monotonicSeconds: 10
            ),
            .init(
                wallClock: Date(timeIntervalSince1970: 1_700_000_004),
                monotonicSeconds: 14
            ),
        ])
        let model = AppModel(
            projectBaseURL: tempBase,
            projectMetadataUpdater: metadataUpdater.update,
            resultViewerTimingReceiptUpdater: receiptUpdater.update,
            resultViewerTimingPairOperations: pairOperations
        )
        model.currentProjectURL = projectURL
        model.outputPlyURL = result.outputURL
        model.viewState = .viewer
        model.prepareResultViewerTiming(
            projectID: metadata.id,
            projectURL: projectURL,
            outputURL: result.outputURL,
            expectedPublicationID: publicationID,
            boundary: .capture(sample: samples.next)
        )

        model.resultViewerDidBecomeReady(
            projectURL: projectURL,
            outputURL: result.outputURL
        )
        _ = try await waitForPublishedViewerTiming(
            paths: paths,
            expectedSeconds: 4
        )
        try await waitForViewerTimingTaskToFinish(model: model)

        model.resultViewerDidBecomeReady(
            projectURL: projectURL,
            outputURL: result.outputURL
        )
        await Task.yield()

        XCTAssertEqual(metadataUpdater.attemptCount, 2)
        XCTAssertEqual(
            receiptUpdater.attemptCount,
            1,
            "A durable receipt must not be republished after metadata retries are exhausted."
        )
        XCTAssertEqual(
            plyValidationCounter.count,
            1,
            "Receipt-bound metadata retries must not hash the PLY again."
        )
        XCTAssertNil(
            try ProjectMetadataStore.load(from: paths.metadataURL)
                .createToViewerReadySeconds
        )
        XCTAssertNil(model.pendingResultViewerTiming)
        XCTAssertEqual(samples.readCount, 2)
    }

    func testResetCancelsPausedViewerTimingReceiptUpdate() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent(
            "Cancelled Viewer Timing.easysplatproj",
            isDirectory: true
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()

        var metadata = ProjectMetadata(
            title: "Cancelled Viewer Timing",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced
            ),
            state: PipelineState(stage: .done, lastError: nil)
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: standardHardwareProfile,
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let publicationID = UUID(
            uuidString: "0f133b74-49b7-40f0-831f-1c69923bf92e"
        )!
        let sourceURL = paths.trainingURL.appendingPathComponent("result.ply")
        try writeMinimalPly(at: sourceURL)
        let result = try publishAppTestResult(
            sourceURL: sourceURL,
            paths: paths,
            metadata: metadata,
            publicationID: publicationID
        )
        let started = expectation(description: "receipt update started")
        let finished = expectation(description: "receipt update finished")
        let receiptUpdater = BlockingViewerTimingReceiptUpdateProbe(
            phase: .beforeUpdate,
            started: started,
            finished: finished
        )
        let samples = LockedRunTimingSamples([
            .init(
                wallClock: Date(timeIntervalSince1970: 1_700_000_000),
                monotonicSeconds: 20
            ),
            .init(
                wallClock: Date(timeIntervalSince1970: 1_700_000_006),
                monotonicSeconds: 26
            ),
        ])
        let model = AppModel(
            projectBaseURL: tempBase,
            resultViewerTimingReceiptUpdater: receiptUpdater.update
        )
        model.currentProjectURL = projectURL
        model.outputPlyURL = result.outputURL
        model.viewState = .viewer
        model.prepareResultViewerTiming(
            projectID: metadata.id,
            projectURL: projectURL,
            outputURL: result.outputURL,
            expectedPublicationID: publicationID,
            boundary: .capture(sample: samples.next)
        )

        model.resultViewerDidBecomeReady(
            projectURL: projectURL,
            outputURL: result.outputURL
        )
        await fulfillment(of: [started], timeout: 2)
        model.reset()
        receiptUpdater.release()
        await fulfillment(of: [finished], timeout: 2)
        await Task.yield()

        let unchangedMetadata = try ProjectMetadataStore.load(
            from: paths.metadataURL
        )
        let unchangedReceipt = try PublishedSplatReceiptStore.load(
            projectPaths: paths
        )
        XCTAssertNil(unchangedMetadata.createToViewerReadySeconds)
        XCTAssertNil(
            unchangedReceipt.presentation.createToViewerReadySeconds
        )
        XCTAssertNil(model.pendingResultViewerTiming)
        XCTAssertNil(model.resultViewerTimingTask)
        XCTAssertEqual(samples.readCount, 2)
    }

    func testPostcommitCancellationFinishesMetadataUnderTheSameTimingLease() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent(
            "Committed Viewer Timing.easysplatproj",
            isDirectory: true
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()

        var metadata = ProjectMetadata(
            title: "Committed Viewer Timing",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced
            ),
            state: PipelineState(stage: .done, lastError: nil)
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: standardHardwareProfile,
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let publicationID = UUID(
            uuidString: "f62db772-72d7-4646-9128-4d9ce0af3f98"
        )!
        let sourceURL = paths.trainingURL.appendingPathComponent("result.ply")
        try writeMinimalPly(at: sourceURL)
        let result = try publishAppTestResult(
            sourceURL: sourceURL,
            paths: paths,
            metadata: metadata,
            publicationID: publicationID
        )
        let committed = expectation(description: "receipt timing committed")
        let updaterFinished = expectation(description: "cancelled updater finished")
        let receiptUpdater = BlockingViewerTimingReceiptUpdateProbe(
            phase: .afterUpdate,
            started: committed,
            finished: updaterFinished
        )
        let firstSamples = LockedRunTimingSamples([
            .init(
                wallClock: Date(timeIntervalSince1970: 1_700_000_000),
                monotonicSeconds: 20
            ),
            .init(
                wallClock: Date(timeIntervalSince1970: 1_700_000_006),
                monotonicSeconds: 26
            ),
        ])
        let metadataUpdater = ViewerTimingMetadataSuccessProbe()
        let model = AppModel(
            projectBaseURL: tempBase,
            projectMetadataUpdater: metadataUpdater.update,
            resultViewerTimingReceiptUpdater: receiptUpdater.update
        )
        model.currentProjectURL = projectURL
        model.outputPlyURL = result.outputURL
        model.viewState = .viewer
        model.prepareResultViewerTiming(
            projectID: metadata.id,
            projectURL: projectURL,
            outputURL: result.outputURL,
            expectedPublicationID: publicationID,
            boundary: .capture(sample: firstSamples.next)
        )

        model.resultViewerDidBecomeReady(
            projectURL: projectURL,
            outputURL: result.outputURL
        )
        await fulfillment(of: [committed], timeout: 2)
        model.reset()
        receiptUpdater.release()
        await fulfillment(of: [updaterFinished], timeout: 2)
        let reconciled = try await waitForPersistedViewerTiming(
            paths: paths,
            expectedSeconds: 6
        )

        XCTAssertEqual(
            try PublishedSplatReceiptStore.load(projectPaths: paths)
                .presentation.createToViewerReadySeconds,
            6
        )
        XCTAssertEqual(reconciled.createToViewerReadySeconds, 6)
        XCTAssertEqual(metadataUpdater.attemptCount, 1)
        XCTAssertNil(model.pendingResultViewerTiming)
    }

    func testReadyProjectHealsMetadataOnlyFromFullyBoundPublishedLineage() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent(
            "Viewer Timing Healing.easysplatproj",
            isDirectory: true
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        var metadata = ProjectMetadata(
            title: "Viewer Timing Healing",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced
            ),
            state: PipelineState(stage: .done, lastError: nil)
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: standardHardwareProfile,
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let publicationID = UUID()
        let sourceURL = paths.trainingURL.appendingPathComponent("healing-result.ply")
        try writeMinimalPly(at: sourceURL)
        let result = try publishAppTestResult(
            sourceURL: sourceURL,
            paths: paths,
            metadata: metadata,
            publicationID: publicationID
        )
        _ = try PublishedResultPairStore.recordFirstViewerReadyTiming(
            6,
            expectedPublicationID: publicationID,
            projectPaths: paths
        )
        let receiptUpdater = ViewerTimingReceiptUpdateProbe()
        let plyValidationCounter = LockedCallCounter()
        var pairOperations = PublishedResultPairOperations.system()
        pairOperations.willValidatePly = { _ in
            plyValidationCounter.record()
        }
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile,
            resultViewerTimingReceiptUpdater: receiptUpdater.update,
            resultViewerTimingPairOperations: pairOperations
        )

        XCTAssertTrue(model.resumeProject(at: projectURL))
        try await waitForViewState(model: model, state: .viewer)
        model.resultViewerDidBecomeReady(
            projectURL: projectURL,
            outputURL: result.outputURL
        )
        let healed = try await waitForPersistedViewerTiming(
            paths: paths,
            expectedSeconds: 6
        )

        XCTAssertEqual(healed.createToViewerReadySeconds, 6)
        XCTAssertEqual(receiptUpdater.attemptCount, 0)
        XCTAssertEqual(
            plyValidationCounter.count,
            1,
            "Healing must make one fully lineage-bound publication decision."
        )
    }

    func testResumeTimingHealingRootSwapBeforeAuthorityCaptureMutatesNeitherRoot() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent(
            "Resume Healing A.easysplatproj",
            isDirectory: true
        )
        let replacementURL = tempBase.appendingPathComponent(
            "Resume Healing B.easysplatproj",
            isDirectory: true
        )
        let parkedOriginalURL = tempBase.appendingPathComponent(
            "Resume Healing A Parked.easysplatproj",
            isDirectory: true
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        var metadata = ProjectMetadata(
            title: "Resume Healing A",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced
            ),
            state: PipelineState(stage: .done, lastError: nil)
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: standardHardwareProfile,
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let publicationID = UUID()
        let sourceURL = paths.trainingURL.appendingPathComponent("healing-a.ply")
        try writeMinimalPly(at: sourceURL)
        let result = try publishAppTestResult(
            sourceURL: sourceURL,
            paths: paths,
            metadata: metadata,
            publicationID: publicationID
        )
        _ = try PublishedResultPairStore.recordFirstViewerReadyTiming(
            8,
            expectedPublicationID: publicationID,
            projectPaths: paths
        )
        try FileManager.default.copyItem(at: projectURL, to: replacementURL)
        let originalMetadata = try Data(contentsOf: paths.metadataURL)
        let originalReceipt = try Data(contentsOf: paths.outputSplatReceiptURL)
        let replacementPaths = ProjectPaths(root: replacementURL)
        let replacementMetadata = try Data(contentsOf: replacementPaths.metadataURL)
        let replacementReceipt = try Data(
            contentsOf: replacementPaths.outputSplatReceiptURL
        )
        let swapProbe = ViewerTimingRootSwapProbe(
            canonicalURL: projectURL,
            replacementURL: replacementURL,
            parkedOriginalURL: parkedOriginalURL
        )
        let receiptUpdater = ViewerTimingReceiptUpdateProbe()
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile,
            projectRunLeaseOwnerAcquirer: { url in
                try swapProbe.swapBeforeOpen()
                return try ProjectRunLeaseOwner.acquire(projectURL: url)
            },
            resultViewerTimingReceiptUpdater: receiptUpdater.update,
            finishedOutputValidator: { _ in result.outputURL }
        )

        XCTAssertTrue(model.resumeProject(at: projectURL))
        try await waitForViewState(model: model, state: .viewer)
        model.resultViewerDidBecomeReady(
            projectURL: projectURL,
            outputURL: result.outputURL
        )
        await Task.yield()

        XCTAssertEqual(swapProbe.attemptCount, 1)
        XCTAssertEqual(
            try Data(
                contentsOf: ProjectPaths(root: parkedOriginalURL).metadataURL
            ),
            originalMetadata
        )
        XCTAssertEqual(
            try Data(
                contentsOf: ProjectPaths(root: parkedOriginalURL)
                    .outputSplatReceiptURL
            ),
            originalReceipt
        )
        XCTAssertEqual(try Data(contentsOf: paths.metadataURL), replacementMetadata)
        XCTAssertEqual(
            try Data(contentsOf: paths.outputSplatReceiptURL),
            replacementReceipt
        )
        XCTAssertNil(model.pendingResultViewerTiming)
        XCTAssertEqual(receiptUpdater.attemptCount, 0)
    }

    func testViewerTimingDoesNotCrossPublicationReplacement() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent(
            "Viewer Timing Generation Race.easysplatproj",
            isDirectory: true
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()

        var metadata = ProjectMetadata(
            title: "Viewer Timing Generation Race",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced
            ),
            state: PipelineState(stage: .done, lastError: nil)
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: standardHardwareProfile,
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let publicationA = UUID(
            uuidString: "aaaaaaaa-1111-4111-8111-111111111111"
        )!
        let sourceA = paths.trainingURL.appendingPathComponent("result-a.ply")
        try writeMinimalPly(at: sourceA)
        let resultA = try publishAppTestResult(
            sourceURL: sourceA,
            paths: paths,
            metadata: metadata,
            publicationID: publicationA
        )
        let committed = expectation(description: "receipt A timing committed")
        let updaterFinished = expectation(description: "receipt updater returned")
        let receiptUpdater = BlockingViewerTimingReceiptUpdateProbe(
            phase: .afterUpdate,
            started: committed,
            finished: updaterFinished
        )
        let samples = LockedRunTimingSamples([
            .init(
                wallClock: Date(timeIntervalSince1970: 1_700_000_000),
                monotonicSeconds: 40
            ),
            .init(
                wallClock: Date(timeIntervalSince1970: 1_700_000_008),
                monotonicSeconds: 48
            ),
        ])
        let model = AppModel(
            projectBaseURL: tempBase,
            resultViewerTimingReceiptUpdater: receiptUpdater.update
        )
        model.currentProjectURL = projectURL
        model.outputPlyURL = resultA.outputURL
        model.viewState = .viewer
        model.prepareResultViewerTiming(
            projectID: metadata.id,
            projectURL: projectURL,
            outputURL: resultA.outputURL,
            expectedPublicationID: publicationA,
            boundary: .capture(sample: samples.next)
        )

        model.resultViewerDidBecomeReady(
            projectURL: projectURL,
            outputURL: resultA.outputURL
        )
        await fulfillment(of: [committed], timeout: 2)

        let publicationB = UUID(
            uuidString: "bbbbbbbb-2222-4222-8222-222222222222"
        )!
        let sourceB = paths.trainingURL.appendingPathComponent("result-b.ply")
        try writeMinimalPly(at: sourceB, vertexCount: 2)
        _ = try publishAppTestResult(
            sourceURL: sourceB,
            paths: paths,
            metadata: metadata,
            publicationID: publicationB
        )
        receiptUpdater.release()
        await fulfillment(of: [updaterFinished], timeout: 2)
        try await waitForViewerTimingTaskToFinish(model: model)

        let currentReceipt = try PublishedSplatReceiptStore.load(
            projectPaths: paths
        )
        let unchangedMetadata = try ProjectMetadataStore.load(
            from: paths.metadataURL
        )
        XCTAssertEqual(currentReceipt.publicationID, publicationB)
        XCTAssertNil(
            currentReceipt.presentation.createToViewerReadySeconds,
            "Publication A timing must not be copied into publication B."
        )
        XCTAssertNil(unchangedMetadata.createToViewerReadySeconds)
        XCTAssertNil(model.pendingResultViewerTiming)
        XCTAssertEqual(samples.readCount, 2)
    }

    func testMissingPublishedReceiptSkipsTimingWithoutHidingHealthyViewer() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(
            at: tempBase,
            withIntermediateDirectories: true
        )
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = LockedRunTimingSamples([
            .init(wallClock: startedAt, monotonicSeconds: 100),
            .init(
                wallClock: startedAt.addingTimeInterval(2),
                monotonicSeconds: 102
            ),
            .init(
                wallClock: startedAt.addingTimeInterval(9),
                monotonicSeconds: 109
            ),
        ])
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            videoInputPreflight: passingVideoPreflight()
        ) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }
        model.addInputs(urls: [input])

        model.startFromPendingSelection(
            timingBoundary: .capture(sample: samples.next)
        )
        try await waitForViewState(model: model, state: .viewer)

        let projectURL = try XCTUnwrap(model.currentProjectURL)
        let outputURL = try XCTUnwrap(model.outputPlyURL)
        let paths = ProjectPaths(root: projectURL)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: paths.outputSplatReceiptURL.path
            )
        )

        model.resultViewerDidBecomeReady(
            projectURL: projectURL,
            outputURL: outputURL
        )

        let metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(model.viewState, .viewer)
        XCTAssertNil(metadata.createToViewerReadySeconds)
        XCTAssertNil(model.pendingResultViewerTiming)
        XCTAssertEqual(
            samples.readCount,
            2,
            "A result without a validated receipt must not consume a timing sample."
        )
    }

    func testPreviousResultViewerReadyDoesNotRecordCreateToViewerTiming() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent(
            "Failed Retrain.easysplatproj",
            isDirectory: true
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()

        let publicationID = UUID(
            uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        )!
        var metadata = ProjectMetadata(
            title: "Failed Retrain",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced
            ),
            state: PipelineState(
                stage: .trainSplat,
                lastError: "The retrain failed."
            )
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: standardHardwareProfile,
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let sourceURL = paths.trainingURL.appendingPathComponent(
            "previous-result.ply"
        )
        try writeMinimalPly(at: sourceURL)
        let previousResult = try publishAppTestResult(
            sourceURL: sourceURL,
            paths: paths,
            metadata: metadata,
            publicationID: publicationID
        )

        let samples = LockedRunTimingSamples([
            .init(
                wallClock: Date(timeIntervalSince1970: 1_700_000_000),
                monotonicSeconds: 20
            ),
            .init(
                wallClock: Date(timeIntervalSince1970: 1_700_000_009),
                monotonicSeconds: 29
            ),
        ])
        let model = AppModel(projectBaseURL: tempBase)
        model.currentProjectURL = projectURL
        model.outputPlyURL = previousResult.outputURL
        model.viewState = .viewer
        model.prepareResultViewerTiming(
            projectID: metadata.id,
            projectURL: projectURL,
            outputURL: previousResult.outputURL,
            boundary: .capture(sample: samples.next)
        )

        model.resultViewerDidBecomeReady(
            projectURL: projectURL,
            outputURL: previousResult.outputURL
        )

        let unchangedMetadata = try ProjectMetadataStore.load(
            from: paths.metadataURL
        )
        let unchangedReceipt = try PublishedSplatReceiptStore.load(
            projectPaths: paths
        )
        XCTAssertNil(unchangedMetadata.createToViewerReadySeconds)
        XCTAssertEqual(unchangedReceipt.publicationID, publicationID)
        XCTAssertNil(
            unchangedReceipt.presentation.createToViewerReadySeconds
        )
        XCTAssertEqual(
            samples.readCount,
            1,
            "A previous result must not consume a new viewer-ready sample."
        )

        _ = try ProjectMetadataStore.update(at: paths.metadataURL) { metadata in
            metadata.createToViewerReadySeconds = 12.5
        }
        model.prepareResultViewerTiming(
            projectID: metadata.id,
            projectURL: projectURL,
            outputURL: previousResult.outputURL,
            expectedPublicationID: publicationID,
            boundary: .capture(sample: samples.next)
        )
        model.resultViewerDidBecomeReady(
            projectURL: projectURL,
            outputURL: previousResult.outputURL
        )
        try await waitForViewerTimingReceiptAttempt(model: model)

        let stillUnchangedReceipt = try PublishedSplatReceiptStore.load(
            projectPaths: paths
        )
        XCTAssertNil(
            stillUnchangedReceipt.presentation.createToViewerReadySeconds,
            "Live project timing must not be copied into a previous result receipt."
        )
        XCTAssertEqual(samples.readCount, 2)
    }

    func testViewerTimingRejectsStalePublicationWithoutHidingHealthyResult() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent(
            "Publication Race.easysplatproj",
            isDirectory: true
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()

        var metadata = ProjectMetadata(
            title: "Publication Race",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced
            ),
            state: PipelineState(stage: .done, lastError: nil)
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: standardHardwareProfile,
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let currentPublicationID = UUID(
            uuidString: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
        )!
        let stalePublicationID = UUID(
            uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        )!
        let sourceURL = paths.trainingURL.appendingPathComponent(
            "current-result.ply"
        )
        try writeMinimalPly(at: sourceURL)
        let currentResult = try publishAppTestResult(
            sourceURL: sourceURL,
            paths: paths,
            metadata: metadata,
            publicationID: currentPublicationID
        )

        let samples = LockedRunTimingSamples([
            .init(
                wallClock: Date(timeIntervalSince1970: 1_700_000_000),
                monotonicSeconds: 20
            ),
            .init(
                wallClock: Date(timeIntervalSince1970: 1_700_000_009),
                monotonicSeconds: 29
            ),
        ])
        let receiptUpdater = ViewerTimingReceiptUpdateProbe()
        let plyValidationCounter = LockedCallCounter()
        var pairOperations = PublishedResultPairOperations.system()
        pairOperations.willValidatePly = { _ in
            plyValidationCounter.record()
        }
        let model = AppModel(
            projectBaseURL: tempBase,
            resultViewerTimingReceiptUpdater: receiptUpdater.update,
            resultViewerTimingPairOperations: pairOperations
        )
        model.currentProjectURL = projectURL
        model.outputPlyURL = currentResult.outputURL
        model.viewState = .viewer
        model.prepareResultViewerTiming(
            projectID: metadata.id,
            projectURL: projectURL,
            outputURL: currentResult.outputURL,
            expectedPublicationID: stalePublicationID,
            boundary: .capture(sample: samples.next)
        )

        model.resultViewerDidBecomeReady(
            projectURL: projectURL,
            outputURL: currentResult.outputURL
        )
        try await waitForViewerTimingTaskToFinish(model: model)

        var unchangedMetadata = try ProjectMetadataStore.load(
            from: paths.metadataURL
        )
        var unchangedReceipt = try PublishedSplatReceiptStore.load(
            projectPaths: paths
        )
        XCTAssertEqual(model.viewState, .viewer)
        XCTAssertEqual(model.outputPlyURL, currentResult.outputURL)
        XCTAssertNil(model.lastError)
        XCTAssertNil(unchangedMetadata.createToViewerReadySeconds)
        XCTAssertEqual(unchangedReceipt.publicationID, currentPublicationID)
        XCTAssertNil(
            unchangedReceipt.presentation.createToViewerReadySeconds
        )
        XCTAssertNil(
            model.pendingResultViewerTiming,
            "A permanent publication mismatch must retire the stale renderer generation."
        )
        XCTAssertEqual(receiptUpdater.attemptCount, 1)
        XCTAssertEqual(plyValidationCounter.count, 1)
        XCTAssertEqual(samples.readCount, 2)

        model.resultViewerDidBecomeReady(
            projectURL: projectURL,
            outputURL: currentResult.outputURL
        )
        await Task.yield()

        unchangedMetadata = try ProjectMetadataStore.load(
            from: paths.metadataURL
        )
        unchangedReceipt = try PublishedSplatReceiptStore.load(
            projectPaths: paths
        )
        XCTAssertNil(unchangedMetadata.createToViewerReadySeconds)
        XCTAssertNil(
            unchangedReceipt.presentation.createToViewerReadySeconds
        )
        XCTAssertEqual(receiptUpdater.attemptCount, 1)
        XCTAssertEqual(
            plyValidationCounter.count,
            1,
            "A retired stale generation must not hash publication B again."
        )
        XCTAssertEqual(
            samples.readCount,
            2,
            "A retry must reuse the original first-ready sample."
        )
    }

    func testResultViewerReadyNeverOverwritesPersistedTiming() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent("Existing.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let projectID = UUID()
        try ProjectMetadataStore.save(
            ProjectMetadata(
                id: projectID,
                title: "Existing",
                input: .video(files: []),
                createToViewerReadySeconds: 12.5
            ),
            to: paths.metadataURL
        )
        let outputURL = paths.outputURL.appendingPathComponent("splat.ply")
        let samples = LockedRunTimingSamples([
            .init(wallClock: Date(timeIntervalSince1970: 1_700_000_000), monotonicSeconds: 20),
            .init(wallClock: Date(timeIntervalSince1970: 1_700_000_001), monotonicSeconds: 21),
        ])
        let model = AppModel(projectBaseURL: tempBase)
        model.currentProjectURL = projectURL
        model.outputPlyURL = outputURL
        model.viewState = .viewer
        model.prepareResultViewerTiming(
            projectID: projectID,
            projectURL: projectURL,
            outputURL: outputURL,
            boundary: .capture(sample: samples.next)
        )

        model.resultViewerDidBecomeReady(projectURL: projectURL, outputURL: outputURL)

        let metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(try XCTUnwrap(metadata.createToViewerReadySeconds), 12.5, accuracy: 1e-12)
        XCTAssertEqual(
            samples.readCount,
            1,
            "An ineligible result with persisted timing must not take a new sample."
        )
    }

    func testRunTimingBoundaryIgnoresWallClockSkew() {
        let wallClockStart = Date(timeIntervalSince1970: 1_700_000_000)

        for wallClockDelta in [-3_600.0, 3_600.0] {
            let samples = LockedRunTimingSamples([
                .init(wallClock: wallClockStart, monotonicSeconds: 50),
                .init(
                    wallClock: wallClockStart.addingTimeInterval(wallClockDelta),
                    monotonicSeconds: 52
                ),
            ])
            let boundary = RunTimingBoundary.capture(sample: samples.next)

            XCTAssertEqual(boundary.elapsedSeconds(), 2, accuracy: 1e-12)
            XCTAssertEqual(boundary.startedAt, wallClockStart)
            XCTAssertEqual(samples.readCount, 2)
        }
    }

    func testRunTimingBoundaryClampsInvalidMonotonicElapsedTime() {
        let wallClockStart = Date(timeIntervalSince1970: 1_700_000_000)
        for endingMonotonicSeconds in [99.0, .nan, .infinity] {
            let samples = LockedRunTimingSamples([
                .init(wallClock: wallClockStart, monotonicSeconds: 100),
                .init(
                    wallClock: wallClockStart,
                    monotonicSeconds: endingMonotonicSeconds
                ),
            ])
            let boundary = RunTimingBoundary.capture(sample: samples.next)

            XCTAssertEqual(boundary.elapsedSeconds(), 0)
            XCTAssertEqual(samples.readCount, 2)
        }
    }

    func testVideoPreflightFailureCreatesNoProjectAndDoesNotPrepareTools() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let valid = base.appendingPathComponent("valid.mov")
        let corrupt = base.appendingPathComponent("bad\nclient.mov")
        try Data("valid".utf8).write(to: valid)
        try Data("corrupt".utf8).write(to: corrupt)
        let tools = CapabilityRecordingToolchainManager()
        var pipelineFactoryCount = 0
        let preflight = VideoInputPreflight(
            limits: .init(
                maximumVideoCount: 4,
                maximumTotalBytes: 1_024 * 1_024,
                minimumFreeSpaceReserveBytes: 0,
                maximumConcurrentDecoders: 2
            ),
            availableCapacity: { _ in Int64.max },
            analyze: { url, _ in
                if try Data(contentsOf: url) == Data("corrupt".utf8) {
                    throw FrameExtractor.ExtractionError.extractionFailed
                }
                return .fixture
            }
        )
        let model = AppModel(
            toolchainManager: tools,
            projectBaseURL: base,
            hardwareProfile: standardHardwareProfile,
            videoInputPreflight: preflight
        ) { projectURL, config in
            pipelineFactoryCount += 1
            return MockPipelineRunner(projectURL: projectURL, config: config)
        }

        await model.startProject(
            input: .video(files: [valid.path, corrupt.path]),
            title: "Unsafe"
        )

        XCTAssertNil(tools.lastRequest)
        XCTAssertEqual(pipelineFactoryCount, 0)
        XCTAssertNil(model.currentProjectURL)
        XCTAssertEqual(model.lastError, "This video couldn’t be read")
        XCTAssertEqual(
            model.errorDetails,
            "Video 2 (bad client.mov): decode failed."
        )
        XCTAssertFalse(model.errorDetails?.contains(base.path) == true)
        let entries = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertFalse(entries.contains { $0.hasSuffix(".easysplatproj") })
        let staging = base.appendingPathComponent(VideoInputPreflight.stagingParentName)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    func testStartProjectUsesCompiledDevelopmentOverridePolicy() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)
        let environment = [
            "EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": "/private/tmp/easysplat-toolchain",
            "EASYSPLAT_CANDIDATE_ROUTE": "colmap",
            "EASYSPLAT_STOP_AFTER_STAGE": PipelineStage.sfmMapping.rawValue,
            "EASYSPLAT_SKIP_TRAINING": "1",
            "EASYSPLAT_BENCHMARK_SEED": "57",
        ]
        var capturedOverrides: DevelopmentOverrides?
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile,
            videoInputPreflight: passingVideoPreflight()
        ) { projectURL, config in
            capturedOverrides = config.developmentOverrides
            return MockPipelineRunner(projectURL: projectURL, config: config)
        }

        await withAppEnvironmentAsync(environment.mapValues(Optional.some)) {
            await model.startProject(input: .video(files: [input.path]), title: "Policy")
        }

        XCTAssertEqual(
            capturedOverrides,
            AppConfig.developmentOverrides(
                environment: environment,
                allowsDevelopmentOverrides: AppConfig.allowsDevelopmentOverrides
            )
        )
    }

    func testCountImageFilesIgnoresUnsupportedAndHidden() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for ext in ["jpg", "JPEG", "png", "heic", "HEIF"] {
            try Data("img".utf8).write(to: folder.appendingPathComponent("photo.\(ext)"))
        }
        try Data("notes".utf8).write(to: folder.appendingPathComponent("README.txt"))
        try Data("hidden".utf8).write(to: folder.appendingPathComponent(".hidden.png"))
        let count = AppModel.countImageFiles(in: folder)
        XCTAssertEqual(count, 5)
    }

    func testCountImageFilesDiscoversSystemDeclaredRawTypesWithoutAFormatSuffixList() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: folder.appendingPathComponent("capture.dng"))

        XCTAssertTrue(try XCTUnwrap(UTType(filenameExtension: "dng")).conforms(to: .rawImage))
        XCTAssertEqual(AppModel.countImageFiles(in: folder), 1)
    }

    func testCountImageFilesRecursesIntoSubfolders() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let sub = folder.appendingPathComponent("burst", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        for index in 0..<4 {
            try Data("img".utf8).write(to: sub.appendingPathComponent("burst\(index).jpg"))
        }
        try Data("img".utf8).write(to: folder.appendingPathComponent("hero.jpg"))
        let count = AppModel.countImageFiles(in: folder)
        XCTAssertEqual(count, 5, "Recursive count should include images in subfolders.")
    }

    func testCountImageFilesStopsAtRecommendationThreshold() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<100 {
            try Data("img".utf8).write(to: folder.appendingPathComponent("photo\(index).jpg"))
        }

        XCTAssertEqual(AppModel.countImageFiles(in: folder), AppModel.minimumRecommendedPhotos)
    }

    func testCountImageFilesStopsAtTheTraversalLimit() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<8 {
            try Data("not an image".utf8).write(
                to: folder.appendingPathComponent("file-\(index).txt")
            )
        }

        XCTAssertNil(AppModel.countImageFiles(in: folder, maximumVisitedEntries: 3))
    }

    func testCountImageFilesReturnsNilForMissingFolder() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString)")
        XCTAssertNil(AppModel.countImageFiles(in: folder))
    }

    func testAddInputsWarnsForThinPhotoFolder() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let folder = base.appendingPathComponent("Thin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<2 {
            try Data("img".utf8).write(to: folder.appendingPathComponent("img\(index).jpg"))
        }
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }
        model.addInputs(urls: [folder])
        XCTAssertEqual(model.pendingPhotoURLs.count, 2, "Folder photos should be ingested as a file list.")
        let warning = try XCTUnwrap(model.selectionWarning)
        XCTAssertTrue(warning.contains("2 photos"), "Warning should mention the actual count, got: \(warning)")
        XCTAssertTrue(warning.contains("Add at least 3"), "Warning should explain the hard floor, got: \(warning)")
        XCTAssertFalse(warning.contains("will still attempt"), "Warning must not promise a run below the hard floor.")

        model.removeAllPhotos()
        XCTAssertTrue(model.pendingPhotoURLs.isEmpty)
        XCTAssertNil(model.selectionWarning)
    }

    func testAddInputsDoesNotApplyPhotoOnlyFloorToMixedInput() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let folder = base.appendingPathComponent("Supplemental", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<2 {
            try Data("img".utf8).write(to: folder.appendingPathComponent("img\(index).jpg"))
        }
        let video = base.appendingPathComponent("capture.mov")
        try Data("video".utf8).write(to: video)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)

        model.addInputs(urls: [video, folder])

        XCTAssertEqual(model.pendingVideoURLs, [video])
        XCTAssertEqual(model.pendingPhotoURLs.count, 2)
        XCTAssertNil(model.selectionWarning)
    }

    func testAddInputsMergesPhotosFromMultipleFolders() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let first = base.appendingPathComponent("First", isDirectory: true)
        let second = base.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        for index in 0..<AppModel.minimumRecommendedPhotos {
            try Data("image-a-\(index)".utf8).write(to: first.appendingPathComponent("photo-\(index).jpg"))
            try Data("image-b-\(index)".utf8).write(to: second.appendingPathComponent("photo-\(index).jpg"))
        }
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)

        model.addInputs(urls: [first, second])

        XCTAssertEqual(model.pendingPhotoURLs.count, AppModel.minimumRecommendedPhotos * 2)
        XCTAssertTrue(model.pendingVideoURLs.isEmpty)
        XCTAssertNil(model.selectionWarning, "Both folders should merge; no folder is discarded.")
    }

    func testAddingSeparateClipsPreservesExplicitContinuousOrdering() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("one.mov")
        let second = root.appendingPathComponent("two.mov")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: root)
        model.requestedRunOptions.inputOrdering = .continuous

        model.addInputs(urls: [first, second])

        XCTAssertEqual(model.requestedRunOptions.inputOrdering, .continuous)
        XCTAssertNil(model.selectionWarning)
    }

    func testAddingPhotosToContinuousVideoResetsOrderingBeforeSubmission() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("capture.mov")
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: photos.appendingPathComponent("frame.jpg"))
        try Data("video".utf8).write(to: video)
        let model = AppModel(toolchainManager: MockToolchainManager())
        defer { model.clearPendingInputs() }
        model.requestedRunOptions.inputOrdering = .continuous

        model.addInputs(urls: [video, photos])

        XCTAssertEqual(model.requestedRunOptions.inputOrdering, .automatic)
        XCTAssertEqual(
            model.selectionWarning,
            "Continuous sequence can't combine videos and photos. Input Order was reset to Automatic."
        )
    }

    func testConstrainedResourceChoiceHasPlainExplanation() {
        XCTAssertFalse(HomeView.maximumPerformanceIsAvailable(memoryGB: 16.5))
        XCTAssertEqual(
            HomeView.resourceUseHelp(memoryGB: 16.5),
            "Maximum Performance is unavailable on Macs with 16 GB of unified memory or less."
        )
        XCTAssertTrue(HomeView.maximumPerformanceIsAvailable(memoryGB: 24))
        XCTAssertNil(HomeView.resourceUseHelp(memoryGB: 24))
    }

    func testDetailAvailabilityHelpExplainsDisabledChoices() {
        XCTAssertEqual(
            HomeView.detailAvailabilityHelp(memoryGB: 8),
            "Balanced and High Detail need more than 8 GB of unified memory."
        )
        XCTAssertEqual(
            HomeView.detailAvailabilityHelp(memoryGB: 16),
            "High Detail needs at least 24 GB of unified memory."
        )
        XCTAssertEqual(
            HomeView.detailAvailabilityHelp(memoryGB: 18),
            "High Detail needs at least 24 GB of unified memory."
        )
        XCTAssertEqual(
            HomeView.detailAvailabilityHelp(memoryGB: 23),
            "High Detail needs at least 24 GB of unified memory."
        )
        XCTAssertNil(HomeView.detailAvailabilityHelp(memoryGB: 24))
    }

    func testMarkProjectOpenedWritesSidecarAndDoesNotTouchMainMetadata() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = base.appendingPathComponent("OpenStamp.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let originalMetadata = ProjectMetadata(
            title: "OpenStamp",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )
        let paths = ProjectPaths(root: projectURL)
        try ProjectMetadataStore.save(originalMetadata, to: paths.metadataURL)
        // Capture the metadata file's bytes so we can prove markProjectOpened
        // did NOT rewrite project.json (and so cannot race a pipeline writer).
        let metadataBytesBefore = try Data(contentsOf: paths.metadataURL)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        model.markProjectOpened(at: projectURL, at: stamp)

        let sidecarMoment = LastOpenedSidecar.load(from: paths.lastOpenedSidecarURL)
        XCTAssertEqual(sidecarMoment, stamp, "Sidecar must hold the persisted timestamp.")

        let metadataBytesAfter = try Data(contentsOf: paths.metadataURL)
        XCTAssertEqual(metadataBytesAfter, metadataBytesBefore,
                       "markProjectOpened must not rewrite project.json — that's the race-fix guarantee.")
    }

    func testFlushPendingNotesSaveLandsLastEdit() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = base.appendingPathComponent("FlushTest.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "FlushTest",
                input: .video(files: []),
                requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
            ),
            to: ProjectPaths(root: projectURL).metadataURL
        )

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }
        model.currentProjectURL = projectURL
        // Schedule a save — the debounce timer has not fired yet.
        model.scheduleNotesSave(at: projectURL, to: "last edit")
        // Flush bypasses the debounce, so the value should land synchronously.
        XCTAssertTrue(model.flushPendingNotesSave())
        XCTAssertEqual(model.notesSaveState, .saved)
        let reloaded = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertEqual(reloaded.notes, "last edit",
                       "flushPendingNotesSave must persist the pending value, not lose it.")
    }

    func testNewSplatFlushesPendingNoteAndReopenLoadsIt() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = try makeProject(
            at: base,
            name: "Navigation Note",
            lastError: nil,
            withOutput: true
        )
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: base
        ) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }
        model.currentProjectURL = projectURL
        model.outputPlyURL = ProjectPaths(root: projectURL).outputURL
            .appendingPathComponent("splat.ply")
        model.viewState = .viewer
        var selectedProjectURL: URL? = ProjectSidebar.selectionID(for: projectURL)

        model.scheduleNotesSave(at: projectURL, to: "navigation persistence")
        RootView.prepareNewSplat(model: model, selectedProjectURL: &selectedProjectURL)

        XCTAssertEqual(model.viewState, .home)
        XCTAssertNil(model.currentProjectURL)
        XCTAssertNil(selectedProjectURL)
        XCTAssertEqual(
            try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL).notes,
            "navigation persistence"
        )

        XCTAssertTrue(model.resumeProject(at: projectURL))
        try await waitForViewState(model: model, state: .viewer)
        XCTAssertEqual(model.currentProjectNotes, "navigation persistence")
    }

    func testFailedNotesFlushKeepsLastEditForRetry() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = base.appendingPathComponent("LateMount.easysplatproj", isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }
        model.currentProjectURL = projectURL
        model.scheduleNotesSave(at: projectURL, to: "final keystroke")

        XCTAssertFalse(model.flushPendingNotesSave())
        XCTAssertEqual(model.pendingNotesSave?.text, "final keystroke")
        guard case .failed = model.notesSaveState else {
            return XCTFail("A failed notes write must remain visible")
        }

        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "LateMount",
                input: .video(files: []),
                requestedRunOptions: RequestedRunOptions()
            ),
            to: ProjectPaths(root: projectURL).metadataURL
        )

        XCTAssertTrue(model.flushPendingNotesSave())
        XCTAssertNil(model.pendingNotesSave)
        XCTAssertEqual(
            try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL).notes,
            "final keystroke"
        )
    }

    func testUpdateProjectNotesDoesNotAlterCurrentProjectNotesProperty() throws {
        // Regression: a previous version of updateProjectNotes reassigned
        // currentProjectNotes to the trimmed persisted value, which fired
        // through the SwiftUI binding and erased trailing whitespace the
        // user was still typing.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = base.appendingPathComponent("NotesRace.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "NotesRace",
                input: .video(files: []),
                requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
            ),
            to: ProjectPaths(root: projectURL).metadataURL
        )

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }
        model.currentProjectURL = projectURL
        model.currentProjectNotes = "Captured  " // trailing whitespace mid-typing

        XCTAssertTrue(model.updateProjectNotes(at: projectURL, to: "Captured  "))
        XCTAssertEqual(model.currentProjectNotes, "Captured  ",
                       "Saving must not rewrite the in-memory binding value with the trimmed text.")
    }

    func testFreshProcessingRunExposesActiveOptionsAndInput() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("clip.mov")
        try Data("video".utf8).write(to: input)

        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile,
            videoInputPreflight: passingVideoPreflight()
        ) { _, _ in
            BlockingPipelineRunner()
        }
        model.requestedRunOptions.capturePath = .walkthrough
        model.requestedRunOptions.detailProfile = .highDetail
        model.addInputs(urls: [input])
        model.startFromPendingSelection()

        try await waitForPipelineState(model: model, stage: .trainSplat)
        XCTAssertEqual(model.viewState, .processing)

        XCTAssertEqual(model.currentRunOptions?.capturePath, .walkthrough)
        XCTAssertEqual(model.currentRunOptions?.detailProfile, .highDetail)
        if case .video(let files) = model.currentInput {
            XCTAssertEqual(files, ["Originals/video-0000.mov"])
        } else {
            XCTFail("Expected active video input while processing.")
        }

        model.cancelCurrentProject(deleteProject: false)
        try await waitForViewState(model: model, state: .home, timeout: 4.0)
    }

    func testFreshDurableRunAppearsActiveInProjectLibraryBeforeCompletion() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("clip.mov")
        try Data("video".utf8).write(to: input)

        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            videoInputPreflight: passingVideoPreflight()
        ) { _, _ in
            BlockingPipelineRunner()
        }
        model.addInputs(urls: [input])
        model.startFromPendingSelection()

        let deadline = Date().addingTimeInterval(2)
        var activeSummary: ProjectSummary?
        while Date() < deadline, activeSummary == nil {
            if let projectURL = model.currentProjectURL {
                activeSummary = model.projectSummaries.first {
                    ProjectSummary.hasSameLocation($0.url, projectURL) && $0.isActive
                }
            }
            if activeSummary == nil {
                try await Task.sleep(nanoseconds: 25_000_000)
            }
        }

        XCTAssertEqual(activeSummary?.status, .inProgress)
        XCTAssertEqual(activeSummary?.title, "clip")
        XCTAssertTrue(model.isRunActive)

        model.lastError = "A stage reported a failure"
        model.viewState = .home
        model.refreshProjectSummaries()
        let currentProjectURL = try XCTUnwrap(model.currentProjectURL)
        let stillActive = model.projectSummaries.first {
            ProjectSummary.hasSameLocation($0.url, currentProjectURL)
        }
        XCTAssertEqual(stillActive?.isActive, true)
        XCTAssertEqual(stillActive?.status, .inProgress)

        model.cancelCurrentProject(deleteProject: false)
        try await waitForViewState(model: model, state: .home, timeout: 4.0)
    }

    func testIdleDeleteMovesProjectToTrashWithoutRemovingItDirectly() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent("Failed.easysplatproj", isDirectory: true)
        let movedURL = tempBase.appendingPathComponent(
            "Moved Failed.easysplatproj",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        var trashedURLs: [URL] = []
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            pipelineRunnerFactory: { url, config in
                MockPipelineRunner(projectURL: url, config: config)
            },
            projectTrashHandler: {
                trashedURLs.append($0)
                try FileManager.default.moveItem(at: $0, to: movedURL)
            }
        )
        model.currentProjectURL = projectURL
        model.viewState = .processing

        model.cancelCurrentProject(deleteProject: true)

        let quarantinedURL = try XCTUnwrap(trashedURLs.first)
        XCTAssertEqual(trashedURLs.count, 1)
        XCTAssertEqual(
            quarantinedURL.deletingLastPathComponent().standardizedFileURL,
            tempBase.standardizedFileURL
        )
        XCTAssertTrue(
            quarantinedURL.lastPathComponent.hasPrefix(
                ".easysplat-trash-"
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedURL.path))
        XCTAssertEqual(model.viewState, .home)
        XCTAssertNil(model.currentProjectURL)
    }

    func testIdleTrashFailureKeepsProjectOpen() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent("Failed.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            pipelineRunnerFactory: { url, config in
                MockPipelineRunner(projectURL: url, config: config)
            },
            projectTrashHandler: { _ in throw CocoaError(.fileWriteUnknown) }
        )
        model.currentProjectURL = projectURL
        model.viewState = .processing

        model.cancelCurrentProject(deleteProject: true)

        XCTAssertEqual(model.viewState, .processing)
        XCTAssertEqual(model.currentProjectURL, projectURL)
        XCTAssertEqual(model.statusTitle, "Couldn’t move project to Trash")
        XCTAssertNotNil(model.lastError)
        XCTAssertEqual(model.actionFailure?.title, "Couldn’t move project to Trash")
        XCTAssertEqual(
            model.actionFailure?.message,
            "The project stayed in place. Check Finder permissions and try again."
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.path))
        XCTAssertTrue(try projectTrashQuarantineURLs(in: tempBase).isEmpty)
    }

    func testTrashSourceSwapPreservesOriginalAndReplacementWithoutCallingHandler() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(
            at: tempBase,
            withIntermediateDirectories: true
        )
        let projectURL = tempBase.appendingPathComponent(
            "Canonical.easysplatproj",
            isDirectory: true
        )
        let replacementURL = tempBase.appendingPathComponent(
            "Replacement.easysplatproj",
            isDirectory: true
        )
        let parkedOriginalURL = tempBase.appendingPathComponent(
            "Parked Original.easysplatproj",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: replacementURL,
            withIntermediateDirectories: true
        )
        let originalMarker = projectURL.appendingPathComponent("identity.txt")
        let replacementMarker = replacementURL.appendingPathComponent("identity.txt")
        try Data("A".utf8).write(to: originalMarker)
        try Data("B".utf8).write(to: replacementMarker)
        let handlerCalls = LockedCallCounter()
        let checkpointHook = ProjectTrashQuarantineCheckpointHook { checkpoint in
            guard checkpoint == .canonicalIdentityValidated else { return }
            try FileManager.default.moveItem(
                at: projectURL,
                to: parkedOriginalURL
            )
            try FileManager.default.moveItem(
                at: replacementURL,
                to: projectURL
            )
        }
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            projectTrashHandler: { _ in handlerCalls.record() },
            projectTrashQuarantineCheckpointHook: checkpointHook
        )
        model.currentProjectURL = projectURL
        model.viewState = .processing

        XCTAssertFalse(model.moveProjectToTrash(at: projectURL))

        XCTAssertEqual(handlerCalls.count, 0)
        XCTAssertEqual(
            try Data(contentsOf: parkedOriginalURL.appendingPathComponent("identity.txt")),
            Data("A".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: projectURL.appendingPathComponent("identity.txt")),
            Data("B".utf8)
        )
        XCTAssertTrue(try projectTrashQuarantineURLs(in: tempBase).isEmpty)
        XCTAssertEqual(model.currentProjectURL, projectURL)
        XCTAssertEqual(model.viewState, .processing)
    }

    func testTrashHandlerFailureRestoresVerifiedProjectWhenCanonicalLeafIsAbsent() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent(
            "Rollback.easysplatproj",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectURL,
            withIntermediateDirectories: true
        )
        let markerURL = projectURL.appendingPathComponent("identity.txt")
        try Data("A".utf8).write(to: markerURL)
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            projectTrashHandler: { _ in throw CocoaError(.fileWriteUnknown) }
        )
        model.currentProjectURL = projectURL
        model.viewState = .processing

        XCTAssertFalse(model.moveProjectToTrash(at: projectURL))

        XCTAssertEqual(try Data(contentsOf: markerURL), Data("A".utf8))
        XCTAssertTrue(try projectTrashQuarantineURLs(in: tempBase).isEmpty)
        XCTAssertEqual(model.actionFailure?.title, "Couldn’t move project to Trash")
    }

    func testTrashHandlerFailurePreservesVerifiedProjectAndForeignCanonicalReplacement() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent(
            "Conflict.easysplatproj",
            isDirectory: true
        )
        let replacementURL = tempBase.appendingPathComponent(
            "Conflict Replacement.easysplatproj",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: replacementURL,
            withIntermediateDirectories: true
        )
        try Data("A".utf8).write(
            to: projectURL.appendingPathComponent("identity.txt")
        )
        try Data("B".utf8).write(
            to: replacementURL.appendingPathComponent("identity.txt")
        )
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            projectTrashHandler: { _ in
                try FileManager.default.moveItem(
                    at: replacementURL,
                    to: projectURL
                )
                throw CocoaError(.fileWriteUnknown)
            }
        )
        model.currentProjectURL = projectURL
        model.viewState = .processing

        XCTAssertFalse(model.moveProjectToTrash(at: projectURL))

        XCTAssertEqual(
            try Data(contentsOf: projectURL.appendingPathComponent("identity.txt")),
            Data("B".utf8)
        )
        let quarantineURLs = try projectTrashQuarantineURLs(in: tempBase)
        XCTAssertEqual(quarantineURLs.count, 1)
        let quarantineURL = try XCTUnwrap(quarantineURLs.first)
        XCTAssertEqual(
            try Data(contentsOf: quarantineURL.appendingPathComponent("identity.txt")),
            Data("A".utf8)
        )
        XCTAssertEqual(
            model.actionFailure?.message,
            "The project folder changed while it was being moved. Every item was preserved. Check Finder and try again."
        )
    }

    func testIdleTrashDoesNotInvokeHandlerWhileAnotherProcessOwnsRunLease() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(
            at: tempBase,
            withIntermediateDirectories: true
        )
        let projectURL = try makeProject(
            at: tempBase,
            name: "Busy Trash",
            lastError: "Stopped",
            withOutput: false,
            stage: .sfmMapping
        )
        let externalLease = try ProjectRunLease.acquire(projectURL: projectURL)
        defer { externalLease.release() }
        var trashedURLs: [URL] = []
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            projectTrashHandler: { trashedURLs.append($0) }
        )
        model.currentProjectURL = projectURL
        model.viewState = .processing

        XCTAssertFalse(model.moveProjectToTrash(at: projectURL))

        XCTAssertTrue(trashedURLs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.path))
        XCTAssertEqual(model.currentProjectURL, projectURL)
        XCTAssertEqual(model.viewState, .processing)
    }

    func testTrashWaitsForBlockedViewerTimingBeforeMovingTheProject() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent(
            "Timing Before Trash.easysplatproj",
            isDirectory: true
        )
        let movedURL = tempBase.appendingPathComponent(
            "Moved Timing Project.easysplatproj",
            isDirectory: true
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        var metadata = ProjectMetadata(
            title: "Timing Before Trash",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced
            ),
            state: PipelineState(stage: .done, lastError: nil)
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: standardHardwareProfile,
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let publicationID = UUID()
        let sourceURL = paths.trainingURL.appendingPathComponent(
            "timing-before-trash.ply"
        )
        try writeMinimalPly(at: sourceURL)
        let result = try publishAppTestResult(
            sourceURL: sourceURL,
            paths: paths,
            metadata: metadata,
            publicationID: publicationID
        )
        let receiptCommitted = expectation(
            description: "viewer timing receipt committed"
        )
        let receiptUpdaterFinished = expectation(
            description: "viewer timing updater returned"
        )
        let trashRan = expectation(description: "project moved after timing")
        let receiptUpdater = BlockingViewerTimingReceiptUpdateProbe(
            phase: .afterUpdate,
            started: receiptCommitted,
            finished: receiptUpdaterFinished
        )
        var timingWasPersistedBeforeMove = false
        let model = AppModel(
            projectBaseURL: tempBase,
            projectTrashHandler: { url in
                timingWasPersistedBeforeMove = try ProjectMetadataStore.load(
                    from: ProjectPaths(root: url).metadataURL
                ).createToViewerReadySeconds == 4
                try FileManager.default.moveItem(at: url, to: movedURL)
                trashRan.fulfill()
            },
            resultViewerTimingReceiptUpdater: receiptUpdater.update
        )
        model.currentProjectURL = projectURL
        model.outputPlyURL = result.outputURL
        model.viewState = .viewer
        let samples = LockedRunTimingSamples([
            .init(wallClock: Date(), monotonicSeconds: 10),
            .init(wallClock: Date(), monotonicSeconds: 14),
        ])
        model.prepareResultViewerTiming(
            projectID: metadata.id,
            projectURL: projectURL,
            outputURL: result.outputURL,
            expectedPublicationID: publicationID,
            boundary: .capture(sample: samples.next)
        )
        model.resultViewerDidBecomeReady(
            projectURL: projectURL,
            outputURL: result.outputURL
        )
        await fulfillment(of: [receiptCommitted], timeout: 2)

        XCTAssertTrue(model.moveProjectToTrash(at: projectURL))
        XCTAssertNotNil(model.deferredProjectMutationTask)
        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: movedURL.path))

        receiptUpdater.release()
        await fulfillment(
            of: [receiptUpdaterFinished, trashRan],
            timeout: 2
        )
        try await waitForDeferredProjectMutationToFinish(model: model)

        XCTAssertTrue(timingWasPersistedBeforeMove)
        let movedPaths = ProjectPaths(root: movedURL)
        XCTAssertEqual(
            try ProjectMetadataStore.load(from: movedPaths.metadataURL)
                .createToViewerReadySeconds,
            4
        )
        XCTAssertEqual(
            try PublishedSplatReceiptStore.load(projectPaths: movedPaths)
                .presentation.createToViewerReadySeconds,
            4
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectURL.path))
        XCTAssertNil(model.currentProjectURL)
    }

    func testStoppedRunKeepsTaskLeaseThroughTrashAndReleasesAfterFinish() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(
            at: tempBase,
            withIntermediateDirectories: true
        )
        let projectURL = try makeProject(
            at: tempBase,
            name: "Stop Then Trash",
            lastError: nil,
            withOutput: false,
            stage: .sfmMapping
        )
        let movedURL = tempBase.appendingPathComponent(
            "Moved Stop Then Trash.easysplatproj",
            isDirectory: true
        )
        var trashObservedHeldLease = false
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile,
            pipelineRunnerFactory: { _, _ in
                BlockingPipelineRunner()
            },
            projectTrashHandler: { url in
                do {
                    let unexpected = try ProjectRunLease.acquire(projectURL: url)
                    unexpected.release()
                } catch ProjectRunLeaseError.alreadyRunning {
                    trashObservedHeldLease = true
                }
                try FileManager.default.moveItem(at: url, to: movedURL)
            }
        )

        XCTAssertTrue(model.resumeProject(at: projectURL))
        try await waitForPipelineState(model: model, stage: .trainSplat)

        model.cancelCurrentProject(deleteProject: true)
        try await waitForRunToFinish(model: model)

        XCTAssertTrue(trashObservedHeldLease)
        XCTAssertEqual(model.viewState, .home)
        XCTAssertNil(model.currentProjectURL)
        let reacquiredLease = try ProjectRunLease.acquire(
            projectURL: movedURL
        )
        reacquiredLease.release()
    }

    func testStoppedRunFlushesPendingNotesWithItsExistingTaskLease() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(
            at: tempBase,
            withIntermediateDirectories: true
        )
        let projectURL = try makeProject(
            at: tempBase,
            name: "Stop With Pending Note",
            lastError: nil,
            withOutput: false,
            stage: .sfmMapping
        )
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile
        ) { _, _ in
            BlockingPipelineRunner()
        }

        XCTAssertTrue(model.resumeProject(at: projectURL))
        try await waitForPipelineState(model: model, stage: .trainSplat)
        model.scheduleNotesSave(at: projectURL, to: "last edit")

        model.cancelCurrentProject(deleteProject: false)
        try await waitForRunToFinish(model: model)

        let persisted = try ProjectMetadataStore.load(
            from: ProjectPaths(root: projectURL).metadataURL
        )
        XCTAssertEqual(persisted.notes, "last edit")
        XCTAssertNil(model.pendingNotesSave)
    }

    func testTrashAbortsWhenPendingNotesCannotBeSaved() {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent("Unsaved.easysplatproj", isDirectory: true)
        var trashedURLs: [URL] = []
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            pipelineRunnerFactory: { url, config in
                MockPipelineRunner(projectURL: url, config: config)
            },
            projectTrashHandler: { trashedURLs.append($0) }
        )
        model.currentProjectURL = projectURL
        model.viewState = .viewer
        model.scheduleNotesSave(at: projectURL, to: "final keystroke")

        XCTAssertFalse(model.moveProjectToTrash(at: projectURL))

        XCTAssertTrue(trashedURLs.isEmpty)
        XCTAssertEqual(model.currentProjectURL, projectURL)
        XCTAssertEqual(model.viewState, .viewer)
        XCTAssertEqual(model.pendingNotesSave?.text, "final keystroke")
        XCTAssertEqual(model.actionFailure?.title, "Couldn’t save notes")
    }

    func testResumeAbortsBeforeChangingRunStateWhenPendingNotesCannotBeSaved() {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let currentProjectURL = tempBase.appendingPathComponent("Unsaved.easysplatproj", isDirectory: true)
        let nextProjectURL = tempBase.appendingPathComponent("Next.easysplatproj", isDirectory: true)
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            pipelineRunnerFactory: { url, config in
                MockPipelineRunner(projectURL: url, config: config)
            }
        )
        model.currentProjectURL = currentProjectURL
        model.viewState = .viewer
        model.scheduleNotesSave(at: currentProjectURL, to: "final keystroke")

        XCTAssertFalse(model.resumeProject(at: nextProjectURL))

        XCTAssertFalse(model.isRunActive)
        XCTAssertNil(model.currentTask)
        XCTAssertEqual(model.currentProjectURL, currentProjectURL)
        XCTAssertEqual(model.viewState, .viewer)
        XCTAssertEqual(model.pendingNotesSave?.text, "final keystroke")
        XCTAssertEqual(model.actionFailure?.title, "Couldn’t save notes")
    }

    func testResumeWaitsForCancelledViewerTimingBeforeActivatingNewProject() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let currentProjectURL = tempBase.appendingPathComponent(
            "Current Timing.easysplatproj",
            isDirectory: true
        )
        let currentPaths = ProjectPaths(root: currentProjectURL)
        try currentPaths.ensureDirectories()
        var currentMetadata = ProjectMetadata(
            title: "Current Timing",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced
            ),
            state: PipelineState(stage: .done, lastError: nil)
        )
        currentMetadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: currentMetadata.requestedRunOptions,
            input: currentMetadata.input,
            hardware: standardHardwareProfile,
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(
            currentMetadata,
            to: currentPaths.metadataURL
        )
        let publicationID = UUID()
        let sourceURL = currentPaths.trainingURL.appendingPathComponent(
            "cancelled-timing.ply"
        )
        try writeMinimalPly(at: sourceURL)
        let currentResult = try publishAppTestResult(
            sourceURL: sourceURL,
            paths: currentPaths,
            metadata: currentMetadata,
            publicationID: publicationID
        )
        let nextProjectURL = try makeProject(
            at: tempBase,
            name: "Next Ready",
            lastError: nil,
            withOutput: true
        )
        let timingStarted = expectation(
            description: "viewer timing updater blocked before commit"
        )
        let timingFinished = expectation(
            description: "cancelled viewer timing updater finished"
        )
        let receiptUpdater = BlockingViewerTimingReceiptUpdateProbe(
            phase: .beforeUpdate,
            started: timingStarted,
            finished: timingFinished
        )
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            resultViewerTimingReceiptUpdater: receiptUpdater.update
        )
        model.currentProjectURL = currentProjectURL
        model.outputPlyURL = currentResult.outputURL
        model.viewState = .viewer
        let samples = LockedRunTimingSamples([
            .init(wallClock: Date(), monotonicSeconds: 20),
            .init(wallClock: Date(), monotonicSeconds: 25),
        ])
        model.prepareResultViewerTiming(
            projectID: currentMetadata.id,
            projectURL: currentProjectURL,
            outputURL: currentResult.outputURL,
            expectedPublicationID: publicationID,
            boundary: .capture(sample: samples.next)
        )
        model.resultViewerDidBecomeReady(
            projectURL: currentProjectURL,
            outputURL: currentResult.outputURL
        )
        await fulfillment(of: [timingStarted], timeout: 2)
        let metadataBefore = try Data(contentsOf: currentPaths.metadataURL)
        let receiptBefore = try Data(
            contentsOf: currentPaths.outputSplatReceiptURL
        )

        XCTAssertTrue(model.resumeProject(at: nextProjectURL))
        XCTAssertNil(
            model.pendingResultViewerTiming,
            "Navigation must retire the old viewer generation before the new task gets its first turn."
        )
        XCTAssertNil(model.resultViewerTimingTask)
        XCTAssertTrue(model.isRunActive)
        XCTAssertTrue(
            ProjectSummary.hasSameLocation(
                model.currentProjectURL,
                currentProjectURL
            ),
            "The next project must not activate while the old timing lease is still held."
        )
        XCTAssertEqual(try Data(contentsOf: currentPaths.metadataURL), metadataBefore)
        XCTAssertEqual(
            try Data(contentsOf: currentPaths.outputSplatReceiptURL),
            receiptBefore
        )

        receiptUpdater.release()
        await fulfillment(of: [timingFinished], timeout: 2)
        try await waitForViewState(model: model, state: .viewer)
        try await waitForRunToFinish(model: model)

        XCTAssertEqual(try Data(contentsOf: currentPaths.metadataURL), metadataBefore)
        XCTAssertEqual(
            try Data(contentsOf: currentPaths.outputSplatReceiptURL),
            receiptBefore
        )
        XCTAssertTrue(
            ProjectSummary.hasSameLocation(model.currentProjectURL, nextProjectURL)
        )
    }

    func testCancellingDeferredResumeRetiresThePendingRunBeforeMutation() async throws {
        try await assertCancellingDeferredProjectMutationRetiresRun(.resume)
    }

    func testCancellingDeferredRetrainRetiresThePendingRunBeforeMutation() async throws {
        try await assertCancellingDeferredProjectMutationRetiresRun(.retrain)
    }

    func testCancellingDeferredRetryRetiresThePendingRunBeforeMutation() async throws {
        try await assertCancellingDeferredProjectMutationRetiresRun(.retry)
    }

    func testReadyProjectOpensReadOnlyWhileAnotherProcessOwnsRunLease() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(
            at: tempBase,
            withIntermediateDirectories: true
        )
        let projectURL = try makeProject(
            at: tempBase,
            name: "Busy Ready Viewer",
            lastError: nil,
            withOutput: true
        )
        let externalLease = try ProjectRunLease.acquire(projectURL: projectURL)
        defer { externalLease.release() }
        var runnerFactoryCallCount = 0
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile
        ) { projectURL, config in
            runnerFactoryCallCount += 1
            return MockPipelineRunner(projectURL: projectURL, config: config)
        }

        XCTAssertTrue(model.resumeProject(at: projectURL))
        try await waitForViewState(model: model, state: .viewer)

        XCTAssertEqual(runnerFactoryCallCount, 0)
        XCTAssertEqual(model.outputPlyURL, ProjectPaths(root: projectURL).outputSplatURL)
    }

    func testUnfinishedProjectDoesNotResumeWhileAnotherProcessOwnsRunLease() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(
            at: tempBase,
            withIntermediateDirectories: true
        )
        let projectURL = try makeProject(
            at: tempBase,
            name: "Busy Resume",
            lastError: nil,
            withOutput: false,
            stage: .sfmMapping
        )
        let paths = ProjectPaths(root: projectURL)
        let bytesBefore = try Data(contentsOf: paths.metadataURL)
        let externalLease = try ProjectRunLease.acquire(projectURL: projectURL)
        defer { externalLease.release() }
        var runnerFactoryCallCount = 0
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile
        ) { projectURL, config in
            runnerFactoryCallCount += 1
            return MockPipelineRunner(projectURL: projectURL, config: config)
        }

        XCTAssertTrue(model.resumeProject(at: projectURL))
        try await waitForRunToFinish(model: model)

        XCTAssertEqual(runnerFactoryCallCount, 0)
        XCTAssertEqual(try Data(contentsOf: paths.metadataURL), bytesBefore)
        XCTAssertEqual(model.lastError, "This project is already being processed.")
        XCTAssertEqual(model.viewState, .processing)
    }

    func testRenameFailureUsesAppLevelActionFailure() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = base.appendingPathComponent("Unreadable.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: ProjectPaths(root: projectURL).metadataURL)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)

        XCTAssertFalse(model.renameProject(at: projectURL, to: "New Name"))
        XCTAssertEqual(model.actionFailure?.title, "Couldn’t rename project")
        XCTAssertEqual(
            model.actionFailure?.message,
            "The project name wasn’t changed. Check folder permissions and try again."
        )
    }

    func testMissingDiagnosticProjectUsesAppLevelActionFailure() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let projectURL = base.appendingPathComponent("Missing.easysplatproj", isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)

        model.copyDiagnosticBundle(forProjectURL: projectURL)

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, model.actionFailure == nil {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.actionFailure?.title, "Couldn’t prepare diagnostics")
        XCTAssertEqual(model.actionFailure?.message, "Check the project files and try again.")
    }

    func testSetupExitPresentationHasNoTrashOrResumePromise() {
        let model = AppModel(toolchainManager: MockToolchainManager())

        let presentation = model.exitConfirmationPresentation

        XCTAssertEqual(presentation.title, "Stop setup?")
        XCTAssertEqual(presentation.message, "EasySplat will stop preparing tools. No project has been created.")
        XCTAssertEqual(presentation.primaryActionTitle, "Stop Setup")
        XCTAssertNil(presentation.destructiveActionTitle)
    }

    func testUseAllPhotoPreflightStopsBeforeToolDownloadOrProjectCreation() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let photos = base.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        for index in 0..<78 {
            let url = photos.appendingPathComponent("photo-\(index).png")
            XCTAssertTrue(try writeTestGrayscaleImage(at: url, value: UInt8(index)))
        }
        let toolchain = CapabilityRecordingToolchainManager()
        let model = AppModel(
            toolchainManager: toolchain,
            projectBaseURL: base,
            hardwareProfile: HardwareProfile(memoryGB: 8, cpuCount: 8, gpuWorkingSetGB: 5)
        ) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }
        model.requestedRunOptions.detailProfile = .fast
        model.requestedRunOptions.photoSelection = .useAllValidPhotos

        await model.startProject(
            input: .photos(folder: photos.path),
            title: "Use all overflow"
        )

        XCTAssertEqual(model.validationRecovery, .useAutomaticPhotoSelection)
        XCTAssertTrue(model.failureRetryAllowed)
        model.retryAfterFailure()
        XCTAssertEqual(model.requestedRunOptions.photoSelection, .automatic)
        XCTAssertNil(model.validationRecovery)
        XCTAssertNil(toolchain.lastRequest)
        XCTAssertNil(model.currentProjectURL)
        XCTAssertFalse(model.isRunActive)
        let projects = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
        XCTAssertFalse(projects.contains { $0.pathExtension == "easysplatproj" })
    }

    func testAutomaticPhotoPreflightRejectsAllCorruptFolderBeforeSetup() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let photos = base.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: photos.appendingPathComponent("broken.jpg"))
        let toolchain = CapabilityRecordingToolchainManager()
        let model = AppModel(toolchainManager: toolchain, projectBaseURL: base) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }
        model.requestedRunOptions.photoSelection = .automatic
        model.addInputs(urls: [photos])

        model.startFromPendingSelection()
        try await waitForLastError(model: model)

        XCTAssertEqual(model.lastError, RunPlanResolver.ValidationError.noValidPhotos.localizedDescription)
        XCTAssertNil(toolchain.lastRequest)
        XCTAssertNil(model.currentProjectURL)
        let projects = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
        XCTAssertFalse(projects.contains { $0.pathExtension == "easysplatproj" })
    }

    func testPhotoPreflightRejectsTwoUsableViewsBeforeSetup() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let photos = base.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        for index in 0..<2 {
            XCTAssertTrue(try writeTestGrayscaleImage(
                at: photos.appendingPathComponent("photo-\(index).png"),
                value: UInt8(index)
            ))
        }
        let toolchain = CapabilityRecordingToolchainManager()
        let model = AppModel(toolchainManager: toolchain, projectBaseURL: base) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }
        model.addInputs(urls: [photos])

        model.startFromPendingSelection()
        try await waitForLastError(model: model)

        XCTAssertEqual(
            model.lastError,
            RunPlanResolver.ValidationError.insufficientValidPhotos(
                actual: 2,
                minimum: 3
            ).localizedDescription
        )
        XCTAssertNil(toolchain.lastRequest)
        XCTAssertNil(model.currentProjectURL)
        let projects = try FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: nil
        )
        XCTAssertFalse(projects.contains { $0.pathExtension == "easysplatproj" })
    }

    func testMixedUseAllPreflightReservesVideoFramesBeforeSetup() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let photos = base.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let video = base.appendingPathComponent("walkthrough.mov")
        try Data("video".utf8).write(to: video)
        let hardware = HardwareProfile(memoryGB: 8, cpuCount: 8, gpuWorkingSetGB: 5)
        let input = InputSpec.mixed(videos: [video.path], photosFolder: photos.path)
        let options = RequestedRunOptions(
            detailProfile: .fast,
            photoSelection: .useAllValidPhotos
        )
        let plan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: input,
            hardware: hardware,
            developmentOverrides: .none
        )
        let maximum = try XCTUnwrap(RunPlanResolver.maximumValidPhotoCount(for: plan, input: input))
        for index in 0...maximum {
            XCTAssertTrue(try writeTestGrayscaleImage(
                at: photos.appendingPathComponent("photo-\(index).png"),
                value: UInt8(index % 255)
            ))
        }
        let toolchain = CapabilityRecordingToolchainManager()
        let model = AppModel(
            toolchainManager: toolchain,
            projectBaseURL: base,
            hardwareProfile: hardware
        ) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }
        model.requestedRunOptions = options

        await model.startProject(input: input, title: "Mixed use all overflow")

        XCTAssertEqual(model.validationRecovery, .useAutomaticPhotoSelection)
        XCTAssertEqual(
            model.lastError,
            RunPlanResolver.ValidationError.photoSelectionExceedsSafeLimit(
                selected: maximum + 1,
                maximum: maximum
            ).localizedDescription
        )
        XCTAssertNil(toolchain.lastRequest)
        XCTAssertNil(model.currentProjectURL)
    }

    func testMixedAutomaticPhotoPreflightRetainsFullBudgetToAbsorbVideoShortfall() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let photos = base.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let video = base.appendingPathComponent("walkthrough.mov")
        try Data("video".utf8).write(to: video)
        let hardware = HardwareProfile(memoryGB: 8, cpuCount: 8, gpuWorkingSetGB: 5)
        let input = InputSpec.mixed(videos: [video.path], photosFolder: photos.path)
        let options = RequestedRunOptions(detailProfile: .fast, photoSelection: .automatic)
        let plan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: input,
            hardware: hardware,
            developmentOverrides: .none
        )
        for index in 0..<plan.keyframeBudget {
            XCTAssertTrue(try writeTestGrayscaleImage(
                at: photos.appendingPathComponent("photo-\(index).png"),
                value: UInt8(index)
            ))
        }
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: base,
            hardwareProfile: hardware,
            videoInputPreflight: passingVideoPreflight()
        ) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }
        model.requestedRunOptions = options

        await model.startProject(input: input, title: "Mixed automatic")

        let projectURL = try XCTUnwrap(model.currentProjectURL)
        let metadata = try ProjectMetadataStore.load(
            from: ProjectPaths(root: projectURL).metadataURL
        )
        XCTAssertEqual(metadata.photoInputReceipts?.count, plan.keyframeBudget)
    }

    func testMixedInputWithNoValidPhotosPersistsAnEmptyControlledPhotoSet() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let photos = base.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: photos.appendingPathComponent("broken.jpg"))
        let video = base.appendingPathComponent("walkthrough.mov")
        try Data("video".utf8).write(to: video)
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: base,
            hardwareProfile: standardHardwareProfile,
            videoInputPreflight: passingVideoPreflight()
        ) { _, _ in
            BlockingPipelineRunner()
        }
        model.addInputs(urls: [video, photos])
        model.startFromPendingSelection()

        try await waitForViewState(model: model, state: .processing)
        let projectURL = try XCTUnwrap(model.currentProjectURL)
        let metadata = try ProjectMetadataStore.load(
            from: ProjectPaths(root: projectURL).metadataURL
        )
        guard case .mixed(let videos, let photoRoot) = metadata.input else {
            return XCTFail("Expected a controlled mixed input.")
        }
        XCTAssertEqual(videos, ["Originals/video-0000.mov"])
        XCTAssertEqual(photoRoot, "Originals/Photos")
        XCTAssertEqual(metadata.photoInputReceipts, [])
        XCTAssertFalse(try String(
            contentsOf: ProjectPaths(root: projectURL).metadataURL,
            encoding: .utf8
        ).contains(photos.path))

        model.cancelCurrentProject(deleteProject: false)
        try await waitForViewState(model: model, state: .home, timeout: 4.0)
    }

    func testUserPhaseElapsedTimeDoesNotResetBetweenInternalStages() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }
        let phaseStart = Date(timeIntervalSince1970: 100)
        model.phaseStartedAt = phaseStart

        model.handle(event: .stageStarted(stage: .importInput))
        XCTAssertEqual(model.phaseStartedAt, phaseStart)

        model.handle(event: .stageStarted(stage: .extractFrames))
        XCTAssertEqual(model.phaseStartedAt, phaseStart)

        model.handle(event: .stageStarted(stage: .sfmFeatures))
        XCTAssertNotEqual(model.phaseStartedAt, phaseStart)
    }

    func testStartProjectPersistsEveryRequestedOption() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("clip.mov")
        try Data("video".utf8).write(to: input)

        let toolchainManager = CapabilityRecordingToolchainManager()
        var runnerPlan: ResolvedRunPlan?
        let model = AppModel(
            toolchainManager: toolchainManager,
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile,
            videoInputPreflight: passingVideoPreflight()
        ) { projectURL, config in
            runnerPlan = config.resolvedRunPlan
            return MockPipelineRunner(projectURL: projectURL, config: config)
        }
        let options = RequestedRunOptions(
            capturePath: .largeArea,
            detailProfile: .highDetail,
            cameraGrouping: .mixedCamerasOrLenses,
            lensProjection: .fisheye,
            inputOrdering: .continuous,
            resourcePolicy: .maximumPerformance,
            photoSelection: .useAllValidPhotos
        )
        model.requestedRunOptions = options

        await model.startProject(input: .video(files: [input.path]), title: "Walkthrough")

        let projectURL = try XCTUnwrap(model.currentProjectURL)
        let metadata = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertEqual(metadata.requestedRunOptions, options)
        let persistedPlan = try XCTUnwrap(metadata.resolvedRunPlan)
        XCTAssertEqual(runnerPlan, persistedPlan)
        XCTAssertEqual(
            toolchainManager.lastRequest,
            try persistedPlan.toolchainCapabilityRequest()
        )
        XCTAssertEqual(model.currentRunOptions, options)
    }

    func testFreshStartUsesInjectedConstrainedHardwareProfile() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("clip.mov")
        try Data("video".utf8).write(to: input)
        var runnerPlan: ResolvedRunPlan?
        let model = AppModel(
            toolchainManager: CapabilityRecordingToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: HardwareProfile(memoryGB: 8, cpuCount: 8, gpuWorkingSetGB: 5),
            videoInputPreflight: passingVideoPreflight()
        ) { projectURL, config in
            runnerPlan = config.resolvedRunPlan
            return MockPipelineRunner(projectURL: projectURL, config: config)
        }
        model.requestedRunOptions.resourcePolicy = .automatic

        await model.startProject(input: .video(files: [input.path]), title: "Constrained")

        let plan = try XCTUnwrap(runnerPlan)
        XCTAssertEqual(plan.memoryTier, "constrained")
        XCTAssertEqual(plan.modelIdentifier, "none")
        XCTAssertEqual(plan.keyframeBudget, 77)
    }

    func testChangingPrimaryRunOptionsPreservesProfessionalChoices() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }
        model.requestedRunOptions.cameraGrouping = .sameCameraAndLens
        model.requestedRunOptions.lensProjection = .fisheye

        model.requestedRunOptions.capturePath = .walkthrough
        model.requestedRunOptions.detailProfile = .fast

        XCTAssertEqual(model.requestedRunOptions.capturePath, .walkthrough)
        XCTAssertEqual(model.requestedRunOptions.detailProfile, .fast)
        XCTAssertEqual(model.requestedRunOptions.cameraGrouping, .sameCameraAndLens)
        XCTAssertEqual(model.requestedRunOptions.lensProjection, .fisheye)
    }

    func testResumedProcessingRunExposesPersistedOptionsAndInput() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let sourcePhotos = tempBase.appendingPathComponent("ResumeSource", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: false)
        for (index, value) in [UInt8(80), 120, 160].enumerated() {
            XCTAssertTrue(try writeTestGrayscaleImage(
                at: sourcePhotos.appendingPathComponent("source-\(index).png"),
                value: value
            ))
        }

        let requestedInput = InputSpec.photos(folder: sourcePhotos.path)
        let requestedOptions = RequestedRunOptions(
            capturePath: .orbit,
            detailProfile: .balanced
        )
        let resolvedPlan = RunPlanResolver.resolve(
            requestedOptions: requestedOptions,
            input: requestedInput,
            hardware: standardHardwareProfile,
            developmentOverrides: .none
        )
        let prepared = try await PhotoInputPreflight.prepare(
            folder: sourcePhotos,
            stagingParent: tempBase,
            photoSelection: resolvedPlan.photoSelection,
            inputOrdering: resolvedPlan.inputOrdering,
            keyframeBudget: resolvedPlan.keyframeBudget,
            requiredAtomicWorkspaceReserveBytes: 0,
            limits: .init(
                maximumPhotoCount: 4,
                maximumTotalBytes: Int64(4) * 1_024 * 1_024,
                maximumSinglePhotoBytes: Int64(1_024) * 1_024,
                maximumPixelCount: Int64(1_024) * 1_024,
                maximumDecodedDimension: 128,
                maximumTraversalEntryCount: 8,
                maximumRecursionDepth: 2,
                minimumFreeSpaceReserveBytes: 0
            ),
            progress: { _, _ in }
        )
        defer { prepared.discard() }
        XCTAssertEqual(prepared.summary.validPhotoCount, 3)
        XCTAssertEqual(prepared.photos.count, 3)
        try RunPlanResolver.validatePhotoSelection(
            validPhotoCount: prepared.summary.validPhotoCount,
            resolvedPlan: resolvedPlan,
            input: requestedInput
        )

        let url = try makeProject(at: tempBase, name: "ResumeConfig", lastError: nil, withOutput: false, stage: .sfmFeatures)
        let paths = ProjectPaths(root: url)
        var adoption = ProjectInputAdoption(requestedInput: requestedInput)
        try adoption.adoptPhotos(prepared, into: paths)
        let persisted = try ProjectMetadataStore.update(at: paths.metadataURL) { metadata in
            metadata.input = adoption.input
            metadata.photoInputReceipts = adoption.photoInputReceipts
            metadata.photoSelectionReceipt = adoption.photoSelectionReceipt
            metadata.resolvedRunPlan = resolvedPlan
        }
        try PhotoInputReceiptValidator.validateFiles(metadata: persisted, paths: paths)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, _ in
            BlockingPipelineRunner()
        }
        model.resumeProject(at: url)

        try await waitForViewState(model: model, state: .processing)

        XCTAssertEqual(model.currentRunOptions?.capturePath, .orbit)
        XCTAssertEqual(model.currentRunOptions?.detailProfile, .balanced)
        if case .photos(let folder) = model.currentInput {
            XCTAssertEqual(folder, "Originals/Photos")
        } else {
            XCTFail("Expected resumed photo-folder input while processing.")
        }

        model.cancelCurrentProject(deleteProject: false)
        try await waitForViewState(model: model, state: .home, timeout: 4.0)
    }

    func testResumedDurableRunAppearsActiveInProjectLibraryBeforeCompletion() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = try makeProject(
            at: tempBase,
            name: "Resume Active",
            lastError: nil,
            withOutput: false,
            stage: .sfmFeatures
        )

        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile
        ) { _, _ in
            BlockingPipelineRunner()
        }
        model.refreshProjectSummaries()
        model.resumeProject(at: projectURL)

        let deadline = Date().addingTimeInterval(2)
        var activeSummary: ProjectSummary?
        while Date() < deadline, activeSummary == nil {
            activeSummary = model.projectSummaries.first {
                ProjectSummary.hasSameLocation($0.url, projectURL) && $0.isActive
            }
            if activeSummary == nil {
                try await Task.sleep(nanoseconds: 25_000_000)
            }
        }

        XCTAssertEqual(activeSummary?.status, .inProgress)
        XCTAssertEqual(activeSummary?.title, "Resume Active")

        model.cancelCurrentProject(deleteProject: false)
        try await waitForViewState(model: model, state: .home, timeout: 4.0)
    }

    func testResumeUsesPersistedRunPlanForToolchainAndRunner() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let url = try makeProject(
            at: tempBase,
            name: "ResumePlan",
            lastError: nil,
            withOutput: false,
            stage: .sfmFeatures
        )
        let paths = ProjectPaths(root: url)
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let options = RequestedRunOptions(detailProfile: .fast, resourcePolicy: .conserveMemory)
        let persistedPlan = RunPlanResolver.resolveForCurrentHardware(
            requestedOptions: options,
            input: metadata.input
        )
        metadata.requestedRunOptions = options
        metadata.resolvedRunPlan = persistedPlan
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchainManager = CapabilityRecordingToolchainManager()
        var runnerPlan: ResolvedRunPlan?
        let model = AppModel(toolchainManager: toolchainManager, projectBaseURL: tempBase) { projectURL, config in
            runnerPlan = config.resolvedRunPlan
            return MockPipelineRunner(projectURL: projectURL, config: config)
        }

        await model.resumeProjectTask(at: url)

        XCTAssertEqual(model.viewState, .viewer)
        XCTAssertEqual(runnerPlan, persistedPlan)
        XCTAssertEqual(
            toolchainManager.lastRequest,
            try persistedPlan.toolchainCapabilityRequest()
        )
    }

    func testResumeProjectUsesCompiledDevelopmentOverridePolicy() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = try makeProject(
            at: tempBase,
            name: "ResumePolicy",
            lastError: nil,
            withOutput: false,
            stage: .sfmFeatures
        )
        let environment = [
            "EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": "/private/tmp/easysplat-toolchain",
            "EASYSPLAT_CANDIDATE_ROUTE": "colmap",
            "EASYSPLAT_STOP_AFTER_STAGE": PipelineStage.sfmMapping.rawValue,
            "EASYSPLAT_SKIP_TRAINING": "1",
            "EASYSPLAT_BENCHMARK_SEED": "57",
        ]
        var capturedOverrides: DevelopmentOverrides?
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile
        ) { url, config in
            capturedOverrides = config.developmentOverrides
            return MockPipelineRunner(projectURL: url, config: config)
        }

        await withAppEnvironmentAsync(environment.mapValues(Optional.some)) {
            await model.resumeProjectTask(at: projectURL)
        }

        XCTAssertEqual(
            capturedOverrides,
            AppConfig.developmentOverrides(
                environment: environment,
                allowsDevelopmentOverrides: AppConfig.allowsDevelopmentOverrides
            )
        )
    }

    func testResumeReplansForCurrentHardwareAndRestartsFramePreparation() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let url = try makeProject(
            at: tempBase,
            name: "MovedMac",
            lastError: nil,
            withOutput: false,
            checkpoint: PipelineCheckpoint(
                stage: .trainSplat,
                updatedAt: Date(),
                progressFraction: 0.5,
                message: "Training",
                details: nil
            ),
            stage: .trainSplat,
            lastRunStartedAt: Date()
        )
        let paths = ProjectPaths(root: url)
        let (_, receipt) = try writeControlledVideoReceipt(paths: paths)
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let options = RequestedRunOptions(detailProfile: .balanced)
        metadata.input = .video(files: [receipt.projectRelativePath])
        metadata.videoInputReceipts = [receipt]
        metadata.requestedRunOptions = options
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: metadata.input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let movedURL = tempBase.appendingPathComponent(
            "MovedMac-Relocated.easysplatproj",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: url, to: movedURL)

        let toolchainManager = CapabilityRecordingToolchainManager()
        let runner = ResumeRecordingPipelineRunner(projectURL: movedURL)
        var runnerPlan: ResolvedRunPlan?
        let model = AppModel(
            toolchainManager: toolchainManager,
            projectBaseURL: tempBase,
            hardwareProfile: HardwareProfile(memoryGB: 16, cpuCount: 10, gpuWorkingSetGB: 12)
        ) { _, config in
            runnerPlan = config.resolvedRunPlan
            return runner
        }

        await model.resumeProjectTask(at: movedURL)

        let plan = try XCTUnwrap(runnerPlan)
        XCTAssertEqual(plan.memoryTier, "constrained")
        XCTAssertEqual(plan.modelIdentifier, "none")
        XCTAssertEqual(plan.keyframeBudget, 160)
        XCTAssertEqual(runner.resumeFrom, .importInput)
        XCTAssertEqual(toolchainManager.lastRequest, try plan.toolchainCapabilityRequest())
    }

    func testUnsupportedResumePreservesCheckpointBeforeToolchainSetup() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let checkpoint = PipelineCheckpoint(
            stage: .trainSplat,
            updatedAt: Date(timeIntervalSince1970: 500),
            progressFraction: 0.5,
            message: "Training",
            details: nil
        )
        let startedAt = Date(timeIntervalSince1970: 400)
        let url = try makeProject(
            at: tempBase,
            name: "HighDetailMovedMac",
            lastError: nil,
            withOutput: false,
            checkpoint: checkpoint,
            stage: .trainSplat,
            lastRunStartedAt: startedAt
        )
        let paths = ProjectPaths(root: url)
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let options = RequestedRunOptions(detailProfile: .highDetail)
        metadata.requestedRunOptions = options
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: metadata.input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchainManager = CapabilityRecordingToolchainManager()
        let model = AppModel(
            toolchainManager: toolchainManager,
            projectBaseURL: tempBase,
            hardwareProfile: HardwareProfile(memoryGB: 16, cpuCount: 10, gpuWorkingSetGB: 12)
        ) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        await model.resumeProjectTask(at: url)

        XCTAssertEqual(model.lastError, RunPlanResolver.ValidationError.highDetailRequiresMoreMemory.localizedDescription)
        XCTAssertEqual(model.validationRecovery, .useBalanced)
        XCTAssertNil(toolchainManager.lastRequest)
        let saved = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(saved.checkpoint?.stage, checkpoint.stage)
        XCTAssertEqual(saved.checkpoint?.updatedAt, checkpoint.updatedAt)
        XCTAssertEqual(saved.checkpoint?.progressFraction, checkpoint.progressFraction)
        XCTAssertEqual(saved.checkpoint?.message, checkpoint.message)
        XCTAssertEqual(saved.lastRunStartedAt, startedAt)
        XCTAssertNil(saved.state.lastError)
    }

    func testValidationRecoveryUpdatesPersistedOptionsBeforeRetry() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = try makeProject(
            at: tempBase,
            name: "RecoverOptions",
            lastError: nil,
            withOutput: false,
            stage: .trainSplat
        )
        let paths = ProjectPaths(root: projectURL)
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        metadata.requestedRunOptions = RequestedRunOptions(detailProfile: .highDetail)
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase)

        XCTAssertTrue(model.applyValidationRecovery(.useBalanced, projectURL: projectURL))

        let recovered = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(recovered.requestedRunOptions.detailProfile, .balanced)
    }

    func testValidationRecoveryLeavesMetadataByteIdenticalWhenAnotherProcessOwnsRunLease() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(
            at: tempBase,
            withIntermediateDirectories: true
        )
        let projectURL = try makeProject(
            at: tempBase,
            name: "Busy Recovery",
            lastError: nil,
            withOutput: false,
            stage: .trainSplat
        )
        let paths = ProjectPaths(root: projectURL)
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        metadata.requestedRunOptions = RequestedRunOptions(
            detailProfile: .highDetail
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let bytesBefore = try Data(contentsOf: paths.metadataURL)
        let externalLease = try ProjectRunLease.acquire(projectURL: projectURL)
        defer { externalLease.release() }
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase
        )

        XCTAssertFalse(
            model.applyValidationRecovery(.useBalanced, projectURL: projectURL)
        )

        XCTAssertEqual(try Data(contentsOf: paths.metadataURL), bytesBefore)
        XCTAssertEqual(model.statusTitle, "This project is already being processed.")
    }

    func testMetalAllocationFailureOffersRetryWithoutChangingTheRunPlan() {
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            hardwareProfile: standardHardwareProfile
        )
        model.validationRecovery = .useFastForMemory
        model.failureRetryAllowed = false
        let error = MsplatMetalAllocationUnavailable(
            iteration: 27,
            requestedBytes: 1_250_000_000,
            currentAllocatedBytes: 7_500_000_000,
            requiredBytes: 8_750_000_000,
            budgetBytes: 12_000_000_000,
            recommendedWorkingSetBytes: 10_000_000_000,
            maximumBufferBytes: 4_000_000_000,
            intersectionCount: 91_000_000
        )

        model.configureRuntimeRecovery(for: error)

        let message = "Training could not reserve unified memory. Close other demanding apps, then try again."
        XCTAssertNil(model.validationRecovery)
        XCTAssertTrue(model.failureRetryAllowed)
        XCTAssertEqual(model.lastError, message)
        XCTAssertEqual(model.statusTitle, message)
        XCTAssertNil(model.statusDetail)
    }

    func testLiveAdmissionFailureOffersRetryWithoutChangingTheRunPlan() {
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            hardwareProfile: standardHardwareProfile
        )
        model.validationRecovery = .useFastForMemory
        model.failureRetryAllowed = false
        let error = TrainingResourceAdmissionError.insufficientAvailableMemory(
            requiredBytes: 12_000_000_000,
            availableBytes: 8_000_000_000
        )

        model.configureRuntimeRecovery(for: error)

        let message = "Training needs more free unified memory. Close other demanding apps, then try again."
        XCTAssertNil(model.validationRecovery)
        XCTAssertTrue(model.failureRetryAllowed)
        XCTAssertEqual(model.lastError, message)
        XCTAssertEqual(model.statusTitle, message)
        XCTAssertNil(model.statusDetail)
    }

    func testResumeToolchainFailurePreservesDurableProjectStateAndArtifacts() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let checkpoint = PipelineCheckpoint(
            stage: .sfmMapping,
            updatedAt: Date(timeIntervalSince1970: 700),
            progressFraction: 1,
            message: "Geometry ready",
            details: nil
        )
        let projectURL = try makeProject(
            at: tempBase,
            name: "ToolchainResumeFailure",
            lastError: nil,
            withOutput: false,
            checkpoint: checkpoint,
            stage: .sfmMapping,
            lastRunStartedAt: Date(timeIntervalSince1970: 650)
        )
        let paths = ProjectPaths(root: projectURL)
        let geometrySentinel = paths.colmapSparseURL
            .appendingPathComponent("0", isDirectory: true)
            .appendingPathComponent("geometry.sentinel")
        let trainingSentinel = paths.trainingURL.appendingPathComponent("checkpoint.sentinel")
        try FileManager.default.createDirectory(
            at: geometrySentinel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("geometry".utf8).write(to: geometrySentinel, options: [.atomic])
        try Data("training".utf8).write(to: trainingSentinel, options: [.atomic])
        let metadataBefore = try Data(contentsOf: paths.metadataURL)

        let model = AppModel(
            toolchainManager: DamagedToolchainManager(
                message: "This EasySplat build is missing its built-in tools. Reinstall EasySplat."
            ),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile
        ) { _, _ in
            XCTFail("Pipeline runner must not start when resume tool setup fails.")
            return BlockingPipelineRunner()
        }

        await model.resumeProjectTask(at: projectURL)

        XCTAssertEqual(
            model.lastError,
            "EasySplat’s built-in tools are missing or damaged. Reinstall EasySplat."
        )
        let errorDetails = try XCTUnwrap(model.errorDetails)
        XCTAssertTrue(errorDetails.contains("missing its built-in tools"))
        XCTAssertEqual(
            model.statusDetail,
            "The saved project and its checkpoint are unchanged."
        )
        XCTAssertEqual(try Data(contentsOf: paths.metadataURL), metadataBefore)
        XCTAssertEqual(try Data(contentsOf: geometrySentinel), Data("geometry".utf8))
        XCTAssertEqual(try Data(contentsOf: trainingSentinel), Data("training".utf8))
    }

    func testCopyTechnicalDetailsPreviewsAndCopiesOnlySanitizedText() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = try makeProject(
            at: tempBase,
            name: "Private Client",
            lastError: nil,
            withOutput: false
        )
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase
        ) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }
        model.currentProjectURL = projectURL
        let raw = """
        \(NSHomeDirectory())/Documents/source.mov
        /Volumes/Client Drive/House/source.mov
        https://alice:secret@example.com/file
        Private Client
        """
        let pasteboard = NSPasteboard(name: .init("EasySplatTests.\(UUID().uuidString)"))
        let probe = "EasySplat pasteboard probe \(UUID().uuidString)"
        pasteboard.clearContents()
        guard pasteboard.setString(probe, forType: .string),
              pasteboard.string(forType: .string) == probe else {
            throw XCTSkip("Pasteboard is unavailable on this test host.")
        }
        var preview = ""

        model.copyTechnicalDetails(raw, pasteboard: pasteboard) { text in
            preview = text
            return true
        }

        XCTAssertFalse(preview.contains(NSHomeDirectory()))
        XCTAssertFalse(preview.contains("Client Drive"))
        XCTAssertFalse(preview.contains("alice"))
        XCTAssertFalse(preview.contains("secret"))
        XCTAssertFalse(preview.contains("Private Client"))
        XCTAssertTrue(preview.contains("https://example.com/file"))
        XCTAssertEqual(pasteboard.string(forType: .string), preview)
    }

    func testUpdateProjectNotesPersistsAndClearsWhenEmpty() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = base.appendingPathComponent("NoteTest.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "NoteTest",
                input: .video(files: []),
                requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
            ),
            to: ProjectPaths(root: projectURL).metadataURL
        )

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }

        XCTAssertTrue(model.updateProjectNotes(at: projectURL, to: "  captured at noon "))
        var reloaded = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertEqual(reloaded.notes, "captured at noon")

        // Identical text returns false (no-op) and does not rewrite.
        XCTAssertFalse(model.updateProjectNotes(at: projectURL, to: "captured at noon"))

        XCTAssertTrue(model.updateProjectNotes(at: projectURL, to: "   "))
        reloaded = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertNil(reloaded.notes)
    }

    func testUpdateProjectNotesLeavesMetadataByteIdenticalWhileRunLeaseIsOwned() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        let projectURL = try makeProject(
            at: base,
            name: "Busy Notes",
            lastError: nil,
            withOutput: true
        )
        let paths = ProjectPaths(root: projectURL)
        let bytesBefore = try Data(contentsOf: paths.metadataURL)
        let externalLease = try ProjectRunLease.acquire(projectURL: projectURL)
        defer { externalLease.release() }
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: base
        )

        XCTAssertFalse(
            model.updateProjectNotes(at: projectURL, to: "must wait")
        )

        XCTAssertEqual(try Data(contentsOf: paths.metadataURL), bytesBefore)
    }

    func testRenameProjectUpdatesPersistedTitle() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = base.appendingPathComponent("Original.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let metadata = ProjectMetadata(
            title: "Original",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )
        try ProjectMetadataStore.save(metadata, to: ProjectPaths(root: projectURL).metadataURL)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }

        XCTAssertTrue(model.renameProject(at: projectURL, to: "  New Title  "))
        let reloaded = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertEqual(reloaded.title, "New Title")
    }

    func testRenameProjectRejectsEmptyOrUnchangedTitles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = base.appendingPathComponent("Same.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let metadata = ProjectMetadata(
            title: "Same",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )
        try ProjectMetadataStore.save(metadata, to: ProjectPaths(root: projectURL).metadataURL)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { url, config in
            MockPipelineRunner(projectURL: url, config: config)
        }

        XCTAssertFalse(model.renameProject(at: projectURL, to: ""))
        XCTAssertFalse(model.renameProject(at: projectURL, to: "   "))
        XCTAssertFalse(model.renameProject(at: projectURL, to: "Same"))
    }

    func testRenameProjectLeavesMetadataByteIdenticalWhileRunLeaseIsOwned() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        let projectURL = try makeProject(
            at: base,
            name: "Busy Rename",
            lastError: nil,
            withOutput: true
        )
        let paths = ProjectPaths(root: projectURL)
        let bytesBefore = try Data(contentsOf: paths.metadataURL)
        let externalLease = try ProjectRunLease.acquire(projectURL: projectURL)
        defer { externalLease.release() }
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: base
        )

        XCTAssertFalse(model.renameProject(at: projectURL, to: "Changed"))

        XCTAssertEqual(try Data(contentsOf: paths.metadataURL), bytesBefore)
    }

    func testUprightPreferenceLeavesMetadataByteIdenticalWhileRunLeaseIsOwned() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true
        )
        let projectURL = try makeProject(
            at: base,
            name: "Busy Upright Preference",
            lastError: nil,
            withOutput: true
        )
        let paths = ProjectPaths(root: projectURL)
        let bytesBefore = try Data(contentsOf: paths.metadataURL)
        let externalLease = try ProjectRunLease.acquire(projectURL: projectURL)
        defer { externalLease.release() }
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: base
        )

        XCTAssertThrowsError(
            try model.updateViewerUprightFlip(
                at: projectURL,
                isActive: true
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectRunLeaseError,
                .alreadyRunning
            )
        }
        XCTAssertEqual(try Data(contentsOf: paths.metadataURL), bytesBefore)
    }

    func testStartProjectPersistsHumanTitleSeparatelyFromSafeBundleLeaf() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let input = base.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)
        let title = String(repeating: "🏠", count: 80) + " / Client\nExterior"
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: base,
            videoInputPreflight: passingVideoPreflight()
        ) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        await model.startProject(input: .video(files: [input.path]), title: title)

        let projectURL = try XCTUnwrap(model.currentProjectURL)
        let metadata = try ProjectMetadataStore.load(
            from: ProjectPaths(root: projectURL).metadataURL
        )
        XCTAssertEqual(metadata.title, title)
        XCTAssertNotEqual(projectURL.deletingPathExtension().lastPathComponent, title)
        XCTAssertLessThanOrEqual(projectURL.lastPathComponent.utf8.count, 240)
        XCTAssertEqual(projectURL.deletingLastPathComponent().standardizedFileURL, base.standardizedFileURL)
    }

    func testStartProjectHandsFreshPublicationAttestationToImmediateRunner() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let input = base.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)
        var recordingRunner: FreshAttestationRecordingPipelineRunner?
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: base,
            videoInputPreflight: passingVideoPreflight()
        ) { projectURL, config in
            let runner = FreshAttestationRecordingPipelineRunner(
                projectURL: projectURL,
                config: config
            )
            recordingRunner = runner
            return runner
        }

        await model.startProject(input: .video(files: [input.path]), title: "Attested")

        XCTAssertEqual(recordingRunner?.freshAttestationRunCount, 1)
        XCTAssertEqual(recordingRunner?.legacyRunCount, 0)
    }

    func testCancellationAfterPublicationDiscardsFreshAttestation() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let input = base.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)
        let runner = FreshAttestationCancellingPipelineRunner()
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: base,
            videoInputPreflight: passingVideoPreflight(),
            pipelineRunnerFactory: { _, _ in runner }
        )

        await model.startProject(input: .video(files: [input.path]), title: "Cancelled Attestation")

        let projectURL = try XCTUnwrap(model.currentProjectURL)
        let metadata = try ProjectMetadataStore.load(
            from: ProjectPaths(root: projectURL).metadataURL
        )
        let attestation = try XCTUnwrap(runner.attestation)
        XCTAssertThrowsError(try attestation.consume(
            projectURL: projectURL,
            metadata: metadata
        )) {
            XCTAssertEqual($0 as? FreshProjectPublicationAttestationError, .discarded)
        }
    }

    func testStartProjectUsesBalancedProfileByDefault() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)
        var capturedPlan: ResolvedRunPlan?

        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile,
            videoInputPreflight: passingVideoPreflight()
        ) { projectURL, config in
            capturedPlan = config.resolvedRunPlan
            return MockPipelineRunner(projectURL: projectURL, config: config)
        }

        XCTAssertEqual(model.requestedRunOptions.detailProfile, .balanced)
        await model.startProject(input: .video(files: [input.path]), title: "BalancedDefault")

        XCTAssertEqual(capturedPlan?.trainerIterationLimit, 30_000)
        let projectURL = try XCTUnwrap(model.currentProjectURL)
        let metadata = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertEqual(metadata.requestedRunOptions.detailProfile, .balanced)
    }

    func testStartProjectUsesFastResolvedPlanForExplicitFastDetail() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)
        var capturedPlan: ResolvedRunPlan?

        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            videoInputPreflight: passingVideoPreflight()
        ) { projectURL, config in
            capturedPlan = config.resolvedRunPlan
            return MockPipelineRunner(projectURL: projectURL, config: config)
        }

        model.requestedRunOptions.detailProfile = .fast
        await model.startProject(input: .video(files: [input.path]), title: "Fast")

        XCTAssertEqual(capturedPlan?.trainerIterationLimit, 3_000)
        XCTAssertEqual(capturedPlan?.modelIdentifier, "none")
        let projectURL = try XCTUnwrap(model.currentProjectURL)
        let metadata = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertEqual(metadata.requestedRunOptions.detailProfile, .fast)
    }

    func testStartProjectReportsFailureWhenRunnerFinishesWithoutReadyOutput() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            videoInputPreflight: passingVideoPreflight()
        ) { projectURL, _ in
            MissingOutputPipelineRunner(projectURL: projectURL)
        }

        await model.startProject(input: .video(files: [input.path]), title: "MissingOutput")

        XCTAssertEqual(model.viewState, .processing)
        XCTAssertNil(model.outputPlyURL)
        XCTAssertEqual(model.lastError, "Processing failed. Expected outputs were missing.")
        XCTAssertEqual(model.statusTitle, "Processing failed. Expected outputs were missing.")
        guard let projectURL = model.currentProjectURL else {
            XCTFail("Missing project URL")
            return
        }
        let metadata = try ProjectMetadataStore.load(from: ProjectPaths(root: projectURL).metadataURL)
        XCTAssertEqual(metadata.state.lastError, "Processing failed. Expected outputs were missing.")
    }

    func testStartProjectToolchainFailureCreatesNoDurableProject() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let model = AppModel(
            toolchainManager: FailingToolchainManager(message: "manifest unreachable"),
            projectBaseURL: tempBase,
            videoInputPreflight: passingVideoPreflight()
        ) { _, _ in
            XCTFail("Pipeline runner should not start when toolchain setup fails.")
            return BlockingPipelineRunner()
        }
        model.addInputs(urls: [input])
        model.startFromPendingSelection()

        try await waitForLastError(model: model, timeout: 4.0)
        model.refreshProjectSummaries()

        XCTAssertEqual(
            model.lastError,
            "Couldn’t prepare the required tools."
        )
        XCTAssertTrue(model.errorDetails?.contains("manifest unreachable") == true)
        XCTAssertNil(model.currentProjectURL)
        XCTAssertNil(model.currentRunOptions)
        XCTAssertNil(model.currentInput)
        XCTAssertEqual(model.pendingVideoURLs, [input])
        XCTAssertTrue(model.pendingPhotoURLs.isEmpty)
        XCTAssertTrue(model.projectSummaries.isEmpty)
        let projectBundles = try FileManager.default.contentsOfDirectory(
            at: tempBase,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "easysplatproj" }
        XCTAssertTrue(projectBundles.isEmpty)
    }

    func testSetupPublicationFailureLeavesNoVisibleOrHiddenPartialProject() async throws {
        for checkpoint: ProjectPublicationTransaction.Checkpoint in [
            .videoAdopted,
            .metadataDurable,
        ] {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: base) }
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let input = base.appendingPathComponent("input.mov")
            try Data("video".utf8).write(to: input)
            let model = AppModel(
                toolchainManager: MockToolchainManager(),
                projectBaseURL: base,
                videoInputPreflight: passingVideoPreflight(),
                pipelineRunnerFactory: { _, _ in
                    XCTFail("The runner must not receive an unpublished project.")
                    return BlockingPipelineRunner()
                },
                projectPublicationCheckpointHook: ProjectPublicationCheckpointHook { reached in
                    if reached == checkpoint { throw InjectedPublicationFailure() }
                }
            )

            await model.startProject(input: .video(files: [input.path]), title: "Interrupted Setup")

            XCTAssertNil(model.currentProjectURL, checkpoint.rawValue)
            XCTAssertTrue(try visibleProjectBundles(in: base).isEmpty, checkpoint.rawValue)
            XCTAssertTrue(try transactionLeaves(in: base).isEmpty, checkpoint.rawValue)
        }
    }

    func testPostRenamePublicationFailureLeavesOneCompleteDiscoverableProject() async throws {
        let checkpoints: [ProjectPublicationTransaction.Checkpoint] = [
            .renameComplete,
            .librarySynced,
            .cleanupIntentDurable,
            .envelopeQuarantined,
            .outerCleanupDurable,
            .bundleCleanupDurable,
            .cleanupProofRemoved,
            .cleanupComplete,
        ]
        for checkpoint in checkpoints {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
            defer { try? FileManager.default.removeItem(at: base) }
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let input = base.appendingPathComponent("input.mov")
            try Data("video".utf8).write(to: input)
            let model = AppModel(
                toolchainManager: MockToolchainManager(),
                projectBaseURL: base,
                videoInputPreflight: passingVideoPreflight(),
                pipelineRunnerFactory: { _, _ in
                    XCTFail("The runner must not start until publication returns.")
                    return BlockingPipelineRunner()
                },
                projectPublicationCheckpointHook: ProjectPublicationCheckpointHook { reached in
                    if reached == checkpoint { throw InjectedPublicationFailure() }
                }
            )

            await model.startProject(input: .video(files: [input.path]), title: "Recovered Project")

            XCTAssertNil(model.currentProjectURL, checkpoint.rawValue)
            let visible = try visibleProjectBundles(in: base)
            XCTAssertEqual(visible.count, 1, checkpoint.rawValue)
            XCTAssertNoThrow(
                try ProjectMetadataStore.load(from: ProjectPaths(root: try XCTUnwrap(visible.first)).metadataURL),
                checkpoint.rawValue
            )
            XCTAssertTrue(try transactionLeaves(in: base).isEmpty, checkpoint.rawValue)
            XCTAssertEqual(model.projectSummaries.count, 1, checkpoint.rawValue)
        }
    }

    func testStartProjectMissingToolchainReleaseExplainsUnavailableBuild() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)
        let model = AppModel(
            toolchainManager: DamagedToolchainManager(
                message: "This EasySplat build is missing its built-in tools. Reinstall EasySplat."
            ),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile,
            videoInputPreflight: passingVideoPreflight()
        ) { _, _ in
            XCTFail("Pipeline runner should not start when the toolchain release is missing.")
            return BlockingPipelineRunner()
        }

        await model.startProject(input: .video(files: [input.path]), title: "MissingTools")

        XCTAssertEqual(
            model.lastError,
            "EasySplat’s built-in tools are missing or damaged. Reinstall EasySplat."
        )
        let errorDetails = try XCTUnwrap(model.errorDetails)
        XCTAssertTrue(errorDetails.contains("missing its built-in tools"))
        XCTAssertNil(model.currentProjectURL)
        XCTAssertTrue(model.projectSummaries.isEmpty)
    }

    func testContinuousMixedInputFailsBeforeToolchainOrProjectCreation() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let video = tempBase.appendingPathComponent("capture.mov")
        let photos = tempBase.appendingPathComponent("Photos", isDirectory: true)
        try Data("video".utf8).write(to: video)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data("photo".utf8).write(to: photos.appendingPathComponent("frame.jpg"))
        let toolchain = CapabilityRecordingToolchainManager()
        let model = AppModel(toolchainManager: toolchain, projectBaseURL: tempBase) { _, _ in
            XCTFail("Pipeline runner should not start for unsupported continuous mixed input.")
            return BlockingPipelineRunner()
        }
        model.addInputs(urls: [video, photos])
        model.requestedRunOptions.inputOrdering = .continuous

        model.startFromPendingSelection()
        try await waitForLastError(model: model, timeout: 4.0)

        XCTAssertEqual(
            model.lastError,
            "Continuous sequence can't combine videos and photos. Use Automatic or Unordered."
        )
        XCTAssertEqual(model.validationRecovery, .useUnordered)
        XCTAssertNil(toolchain.lastRequest)
        XCTAssertNil(model.currentProjectURL)
        let projectBundles = try FileManager.default.contentsOfDirectory(
            at: tempBase,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "easysplatproj" }
        XCTAssertTrue(projectBundles.isEmpty)
    }

    func testTrainingStopCopyPromisesValidationNotAutomaticResume() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }
        model.currentProjectURL = tempBase.appendingPathComponent("Training.easysplatproj", isDirectory: true)
        model.currentTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        defer {
            model.currentTask?.cancel()
            model.currentTask = nil
        }

        model.handle(event: .stageStarted(stage: .trainSplat))
        model.cancelCurrentProject(deleteProject: false)

        XCTAssertEqual(model.statusTitle, "Saving training checkpoint…")
        XCTAssertEqual(
            model.statusDetail,
            "Saving and validating the latest training checkpoint. Recent iterations may repeat on resume."
        )
    }

    func testNonTrainingStopMakesNoHardTimingPromise() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }
        model.currentProjectURL = tempBase.appendingPathComponent("Reconstruction.easysplatproj", isDirectory: true)
        model.currentTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        defer {
            model.currentTask?.cancel()
            model.currentTask = nil
        }

        model.handle(event: .stageStarted(stage: .sfmMapping))
        model.cancelCurrentProject(deleteProject: false)

        XCTAssertEqual(model.statusTitle, "Saving progress…")
        XCTAssertEqual(
            model.statusDetail,
            "Keeping completed work and stopping at a safe point…"
        )
    }

    func testMsplatCheckpointPersistenceFailureDoesNotSilentlyCompleteStop() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)
        let started = expectation(description: "training started")
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            videoInputPreflight: passingVideoPreflight()
        ) { _, _ in
            StopFailingPipelineRunner(started: started, stage: .trainSplat)
        }
        var terminationReplies: [Bool] = []
        model.replyToTerminationRequest = { shouldTerminate in
            terminationReplies.append(shouldTerminate)
        }
        model.addInputs(urls: [input])
        model.startFromPendingSelection()
        await fulfillment(of: [started], timeout: 2.0)
        try await waitForPipelineState(model: model, stage: .trainSplat)

        model.cancelCurrentProject(deleteProject: false, exitIntent: .quit)
        try await waitForLastError(model: model, timeout: 2.0)

        XCTAssertEqual(model.viewState, .processing)
        XCTAssertEqual(model.statusTitle, "Couldn’t save the project")
        XCTAssertEqual(
            model.statusDetail,
            "The training checkpoint was not saved. Review the details and try again."
        )
        XCTAssertFalse(model.isStopping)
        XCTAssertEqual(model.exitIntent, .none)
        XCTAssertNil(model.pendingCloseWindow)
        XCTAssertEqual(terminationReplies, [false])
        XCTAssertNotNil(model.currentProjectURL)
        XCTAssertEqual(
            model.lastError,
            "The training checkpoint was not saved. Review the details and try again."
        )
        XCTAssertTrue(model.errorDetails?.contains("checkpoint persistence failed") == true)
    }

    func testStopFailurePresentationCoversCheckpointGenericAndDeleteFailures() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }
        model.currentProjectURL = tempBase.appendingPathComponent("FailureCopy.easysplatproj", isDirectory: true)

        model.stage = .trainSplat
        XCTAssertEqual(
            model.stopFailurePresentation(for: .keepProject),
            AppModel.StopFailurePresentation(
                title: "Couldn’t save the project",
                detail: "The training checkpoint was not saved. Review the details and try again."
            )
        )

        model.stage = .sfmMapping
        XCTAssertEqual(
            model.stopFailurePresentation(for: .keepProject),
            AppModel.StopFailurePresentation(
                title: "Couldn’t save the project",
                detail: "The project was not saved. Review the details and try again."
            )
        )
        XCTAssertEqual(
            model.stopFailurePresentation(for: .deleteProject),
            AppModel.StopFailurePresentation(
                title: "Couldn’t move project to Trash",
                detail: "The project stayed in place because EasySplat could not stop safely. Review the details and try again."
            )
        )
    }

    func testResumedMsplatCheckpointFailureUsesCheckpointFailureCopy() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = try makeProject(
            at: tempBase,
            name: "ResumeCheckpointFailure",
            lastError: nil,
            withOutput: false,
            stage: .trainSplat
        )
        let started = expectation(description: "resumed training started")
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile
        ) { _, _ in
            StopFailingPipelineRunner(started: started, stage: .trainSplat)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false

        model.resumeProject(at: projectURL)
        await fulfillment(of: [started], timeout: 2.0)
        try await waitForPipelineState(model: model, stage: .trainSplat)

        model.cancelCurrentProject(
            deleteProject: false,
            exitIntent: .closeWindow,
            window: window
        )
        try await waitForLastError(model: model, timeout: 2.0)

        XCTAssertEqual(model.viewState, .processing)
        XCTAssertEqual(model.statusTitle, "Couldn’t save the project")
        XCTAssertEqual(
            model.statusDetail,
            "The training checkpoint was not saved. Review the details and try again."
        )
        XCTAssertFalse(model.isStopping)
        XCTAssertEqual(model.exitIntent, .none)
        XCTAssertNil(model.pendingCloseWindow)
        XCTAssertFalse(model.allowNextWindowClose)
        XCTAssertEqual(model.currentProjectURL, projectURL)
        XCTAssertEqual(
            model.lastError,
            "The training checkpoint was not saved. Review the details and try again."
        )
        XCTAssertTrue(model.errorDetails?.contains("checkpoint persistence failed") == true)
    }

    func testAddInputsIgnoresNonVideoAndClearsWarning() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let video = tempBase.appendingPathComponent("input.mov")
        let text = tempBase.appendingPathComponent("note.txt")
        try? Data("video".utf8).write(to: video)
        try? Data("text".utf8).write(to: text)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }

        model.addInputs(urls: [video, text])
        XCTAssertEqual(model.pendingVideoURLs.count, 1)
        XCTAssertNotNil(model.selectionWarning)

        model.addInputs(urls: [video])
        XCTAssertNil(model.selectionWarning)
    }

    func testAddInputsDeduplicatesVideos() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let video = tempBase.appendingPathComponent("input.mov")
        try? Data("video".utf8).write(to: video)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }

        model.addInputs(urls: [video])
        model.addInputs(urls: [video])
        XCTAssertEqual(model.pendingVideoURLs.count, 1)
    }

    func testAddInputsDeduplicatesRepeatedVideoWithinOneSelection() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let video = base.appendingPathComponent("capture.mov")
        try Data("video".utf8).write(to: video)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)

        model.addInputs(urls: [video, video])

        XCTAssertEqual(model.pendingVideoURLs, [video])
        XCTAssertNil(model.selectionWarning)
    }

    func testAddInputsDeduplicatesEquivalentPathSpellingsAcrossSelections() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        let video = base.appendingPathComponent("capture.mov")
        try Data("video".utf8).write(to: video)
        let alternateSpelling = URL(
            fileURLWithPath: base.path + "/nested/../capture.mov"
        )
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)

        model.addInputs(urls: [alternateSpelling])
        model.addInputs(urls: [video])

        XCTAssertEqual(model.pendingVideoURLs, [alternateSpelling])
        XCTAssertNil(model.selectionWarning)
    }

    func testAddInputsRejectsSymlinksAndDeduplicatesHardLinksByFileIdentity() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let video = base.appendingPathComponent("capture.mov")
        let symlink = base.appendingPathComponent("capture-symlink.mov")
        let hardLink = base.appendingPathComponent("capture-hardlink.mov")
        try Data("video".utf8).write(to: video)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: video)
        try FileManager.default.linkItem(at: video, to: hardLink)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)

        model.addInputs(urls: [symlink, video, hardLink])

        XCTAssertEqual(model.pendingVideoURLs, [video])
        XCTAssertEqual(model.selectionWarning, "Skipped 1 file EasySplat can't use as capture input.")
    }

    func testAddInputsKeepsDistinctFilesWithTheSameBasenameInUserOrder() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let firstDirectory = base.appendingPathComponent("First", isDirectory: true)
        let secondDirectory = base.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondDirectory, withIntermediateDirectories: true)
        let first = firstDirectory.appendingPathComponent("capture.mov")
        let second = secondDirectory.appendingPathComponent("capture.mov")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)

        model.addInputs(urls: [second, first])

        XCTAssertEqual(model.pendingVideoURLs, [second, first])
        XCTAssertNil(model.selectionWarning)
    }

    func testAddInputsRejectsVideoSymlinkWhoseTargetIsNotARegularFile() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let fifo = base.appendingPathComponent("capture-pipe")
        XCTAssertEqual(mkfifo(fifo.path, S_IRUSR | S_IWUSR), 0)
        let symlink = base.appendingPathComponent("capture.mov")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fifo)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)

        model.addInputs(urls: [symlink])

        XCTAssertTrue(model.pendingVideoURLs.isEmpty)
        XCTAssertEqual(
            model.selectionWarning,
            "Ignored 1 file. Add photos, a video, or a folder of them."
        )
    }

    func testAddInputsMergesFolderPhotosAndDeduplicatesEquivalentPaths() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let selected = base.appendingPathComponent("Selected", isDirectory: true)
        let nested = selected.appendingPathComponent("nested", isDirectory: true)
        let second = base.appendingPathComponent("Second", isDirectory: true)
        let third = base.appendingPathComponent("Third", isDirectory: true)
        for folder in [nested, second, third] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<AppModel.minimumRecommendedPhotos {
                try Data("image-\(folder.lastPathComponent)-\(index)".utf8).write(
                    to: folder.appendingPathComponent("photo-\(index).jpg")
                )
            }
        }
        let alternateSpelling = URL(fileURLWithPath: selected.path + "/nested/..", isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)

        // `selected` and its `nested/..` spelling resolve to the same photos, so
        // only their distinct files count once. `second` and `third` contribute
        // their own. The photos live one level down in `nested`.
        model.addInputs(urls: [selected, alternateSpelling, second, third])

        XCTAssertEqual(model.pendingPhotoURLs.count, AppModel.minimumRecommendedPhotos * 3)
        XCTAssertNil(model.selectionWarning, "All folders merge; none is discarded.")

        // Re-adding the same sources contributes nothing new.
        model.addInputs(urls: [second])

        XCTAssertEqual(model.pendingPhotoURLs.count, AppModel.minimumRecommendedPhotos * 3)
        XCTAssertNil(model.selectionWarning)
    }

    func testAddInputsAcceptsSupportedVideoExtensionsWithoutSystemTypeRegistration() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let extensions = ["3gp", "avi", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "mts", "qt"]
        let videos = try extensions.enumerated().map { index, pathExtension in
            let url = tempBase.appendingPathComponent("input-\(index).\(pathExtension.uppercased())")
            try Data("video".utf8).write(to: url)
            return url
        }
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase
        ) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }

        model.addInputs(urls: videos)

        XCTAssertEqual(model.pendingVideoURLs, videos)
        XCTAssertNil(model.selectionWarning)
    }

    func testStartFromPendingSelectionWithNoInputsDoesNothing() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }
        model.startFromPendingSelection()
        XCTAssertEqual(model.viewState, .home)
    }

    func testResumeProjectShortCircuitsWhenOutputExists() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let output = paths.outputURL.appendingPathComponent("splat.ply")
        try FileManager.default.createDirectory(at: paths.outputURL, withIntermediateDirectories: true)
        try writeMinimalPly(at: output)

        let options = RequestedRunOptions(detailProfile: .highDetail)
        var metadata = ProjectMetadata(
            title: "Project",
            input: .video(files: []),
            requestedRunOptions: options,
            state: PipelineState(stage: .done, lastError: nil)
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: metadata.input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        try persistCompletedAppTestArtifacts(
            metadata: metadata,
            paths: paths,
            trainingArtifact: makeCompletedTrainingArtifact(
                for: output,
                metadata: metadata
            )
        )

        let toolchainManager = CapabilityRecordingToolchainManager()
        let model = AppModel(
            toolchainManager: toolchainManager,
            projectBaseURL: tempBase,
            hardwareProfile: HardwareProfile(memoryGB: 16, cpuCount: 10, gpuWorkingSetGB: 12)
        ) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        model.resumeProject(at: projectURL)
        try await waitForViewState(model: model, state: .viewer)
        XCTAssertEqual(model.viewState, .viewer)
        XCTAssertEqual(model.outputPlyURL, output)
        XCTAssertNil(toolchainManager.lastRequest)
    }

    func testResumeProjectShowsOpeningStateWhileValidatingFinishedOutput() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = try makeProject(at: tempBase, name: "Finished", lastError: nil, withOutput: true)
        let output = ProjectPaths(root: projectURL).outputURL.appendingPathComponent("splat.ply")

        let validationStarted = DispatchSemaphore(value: 0)
        let allowValidationToFinish = DispatchSemaphore(value: 0)
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile,
            pipelineRunnerFactory: { url, config in
                MockPipelineRunner(projectURL: url, config: config)
            },
            finishedOutputValidator: { _ in
                validationStarted.signal()
                _ = allowValidationToFinish.wait(timeout: .now() + 2)
                return output
            }
        )

        model.resumeProject(at: projectURL)
        let validationStartResult = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: validationStarted.wait(timeout: .now() + 1))
            }
        }
        XCTAssertEqual(validationStartResult, .success)
        XCTAssertEqual(model.viewState, .opening)

        // Opening a finished project must never present the pipeline progress
        // screen while its output is being validated.
        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline {
            XCTAssertNotEqual(model.viewState, .processing)
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        allowValidationToFinish.signal()
        try await waitForViewState(model: model, state: .viewer)
        XCTAssertEqual(model.outputPlyURL, output)
    }

    func testResumeProjectKeepsOpenedProjectCurrentForTheWholeOpen() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = try makeProject(at: tempBase, name: "Finished", lastError: nil, withOutput: true)
        let output = ProjectPaths(root: projectURL).outputURL.appendingPathComponent("splat.ply")

        let validationStarted = DispatchSemaphore(value: 0)
        let allowValidationToFinish = DispatchSemaphore(value: 0)
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile,
            pipelineRunnerFactory: { url, config in
                MockPipelineRunner(projectURL: url, config: config)
            },
            finishedOutputValidator: { _ in
                validationStarted.signal()
                _ = allowValidationToFinish.wait(timeout: .now() + 2)
                return output
            }
        )

        model.resumeProject(at: projectURL)

        // The sidebar's lock and trash-cancel branch key on currentProjectURL,
        // so a run must never be active without it — not even for the slice
        // between the click and the task's first turn.
        XCTAssertTrue(model.isRunActive)
        XCTAssertTrue(ProjectSummary.hasSameLocation(model.currentProjectURL, projectURL))

        let validationStartResult = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: validationStarted.wait(timeout: .now() + 1))
            }
        }
        XCTAssertEqual(validationStartResult, .success)
        XCTAssertTrue(ProjectSummary.hasSameLocation(model.currentProjectURL, projectURL))

        allowValidationToFinish.signal()
        try await waitForViewState(model: model, state: .viewer)
        XCTAssertTrue(ProjectSummary.hasSameLocation(model.currentProjectURL, projectURL))
    }

    func testResumeProjectFallsThroughToProcessingWhenOutputValidationFails() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = try makeProject(at: tempBase, name: "Unfinished", lastError: nil, withOutput: false)

        let validationStarted = DispatchSemaphore(value: 0)
        let allowValidationToFinish = DispatchSemaphore(value: 0)
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile,
            pipelineRunnerFactory: { _, _ in BlockingPipelineRunner() },
            finishedOutputValidator: { _ in
                validationStarted.signal()
                _ = allowValidationToFinish.wait(timeout: .now() + 2)
                return nil
            }
        )

        model.resumeProject(at: projectURL)
        let validationStartResult = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: validationStarted.wait(timeout: .now() + 1))
            }
        }
        XCTAssertEqual(validationStartResult, .success)
        XCTAssertEqual(model.viewState, .opening)

        allowValidationToFinish.signal()
        try await waitForViewState(model: model, state: .processing)

        model.cancelCurrentProject(deleteProject: false)
        try await waitForViewState(model: model, state: .home, timeout: 4.0)
        XCTAssertFalse(model.isRunActive)
    }

    func testResumeProjectRunsPipelineWhenOutputPathIsDirectory() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let output = paths.outputURL.appendingPathComponent("splat.ply")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let metadata = ProjectMetadata(
            title: "Project",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            state: PipelineState(stage: .done, lastError: nil)
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let runner = DirectoryOutputRepairingPipelineRunner(projectURL: projectURL)
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile
        ) { _, _ in
            runner
        }

        model.resumeProject(at: projectURL)
        try await waitForViewState(model: model, state: .viewer)

        XCTAssertTrue(runner.didRun)
        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path, isDirectory: &isDirectory))
        XCTAssertFalse(isDirectory.boolValue)
    }

    func testResumeProjectRunsPipelineWhenPersistedOutputIsCorrupt() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let output = paths.outputURL.appendingPathComponent("splat.ply")
        try "ply".write(to: output, atomically: true, encoding: .utf8)

        let metadata = ProjectMetadata(
            title: "Project",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            state: PipelineState(stage: .done, lastError: nil)
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let runner = DirectoryOutputRepairingPipelineRunner(projectURL: projectURL)
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile
        ) { _, _ in
            runner
        }

        model.resumeProject(at: projectURL)
        try await waitForViewState(model: model, state: .viewer)

        XCTAssertTrue(runner.didRun)
        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: output), .valid)
    }

    func testStartAndResumeRequestsAreIgnoredWhileRunIsActive() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let firstURL = try makeProject(at: tempBase, name: "First", lastError: nil, withOutput: false)
        let secondURL = try makeProject(at: tempBase, name: "Second", lastError: nil, withOutput: false)
        var callCount = 0
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile
        ) { _, _ in
            callCount += 1
            return BlockingPipelineRunner()
        }

        model.resumeProject(at: firstURL)
        try await waitForViewState(model: model, state: .processing)
        try await waitForCurrentProjectURL(model: model, url: firstURL)
        let input = tempBase.appendingPathComponent("other.mov")
        try Data("video".utf8).write(to: input)
        model.addInputs(urls: [input])

        model.resumeProject(at: secondURL)
        model.startFromPendingSelection()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(model.isRunActive)
        XCTAssertNotNil(model.currentTask)
        XCTAssertEqual(model.currentProjectURL, firstURL)
        XCTAssertEqual(callCount, 1)

        model.cancelCurrentProject(deleteProject: false)
        try await waitForViewState(model: model, state: .home, timeout: 4.0)
        XCTAssertFalse(model.isRunActive)
    }

    func testRetrainProjectBypassesFinishedOutputAndRestartsFramePreparation() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let output = paths.outputURL.appendingPathComponent("splat.ply")
        try FileManager.default.createDirectory(at: paths.outputURL, withIntermediateDirectories: true)
        try writeMinimalPly(at: output)

        var metadata = ProjectMetadata(
            title: "Project",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(detailProfile: .balanced),
            state: PipelineState(stage: .done, lastError: nil)
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: standardHardwareProfile,
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        try persistCompletedAppTestArtifacts(
            metadata: metadata,
            paths: paths,
            trainingArtifact: makeCompletedTrainingArtifact(for: output, metadata: metadata)
        )

        let runner = ResumeRecordingPipelineRunner(projectURL: projectURL)
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile
        ) { _, _ in
            runner
        }

        XCTAssertTrue(model.retrainProject(at: projectURL, profile: .highDetail))
        try await waitForViewState(model: model, state: .viewer)

        // The changed profile moves frame budgets, so the run must restart at
        // frame preparation instead of short-circuiting to the viewer.
        XCTAssertEqual(runner.resumeFrom, .extractFrames)
        let persisted = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(persisted.requestedRunOptions.detailProfile, .highDetail)
    }

    func testRetrainSameProfileRestartsAtTheTrainingBoundaryForNewBudgets() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let output = paths.outputURL.appendingPathComponent("splat.ply")
        try FileManager.default.createDirectory(at: paths.outputURL, withIntermediateDirectories: true)
        try writeMinimalPly(at: output)

        var metadata = ProjectMetadata(
            title: "Project",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(detailProfile: .balanced),
            state: PipelineState(stage: .done, lastError: nil)
        )
        // A project finished under the previous fixed balanced budget: only the
        // trainer fields differ from what current hardware resolves.
        var legacyPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: standardHardwareProfile,
            developmentOverrides: .none
        )
        legacyPlan.trainerIterationLimit = 7_000
        legacyPlan.plateauWindow = 800
        metadata.resolvedRunPlan = legacyPlan
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        try persistCompletedAppTestArtifacts(
            metadata: metadata,
            paths: paths,
            trainingArtifact: makeCompletedTrainingArtifact(for: output, metadata: metadata)
        )

        let runner = ResumeRecordingPipelineRunner(projectURL: projectURL)
        var capturedConfig: PipelineRunner.PipelineConfig?
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile
        ) { _, config in
            capturedConfig = config
            return runner
        }

        XCTAssertTrue(model.retrainProject(at: projectURL, profile: .balanced))
        try await waitForViewState(model: model, state: .viewer)

        XCTAssertEqual(runner.resumeFrom, .sfmMapping)
        XCTAssertEqual(capturedConfig?.runIntent, .retrain)
        let persisted = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(persisted.requestedRunOptions.detailProfile, .balanced)
    }

    func testRetrainSameCurrentProfileStillRestartsAtTrainingBoundary() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(
            at: tempBase,
            withIntermediateDirectories: true
        )
        let projectURL = tempBase.appendingPathComponent(
            "Project.easysplatproj",
            isDirectory: true
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try writeMinimalPly(at: paths.outputSplatURL)

        var metadata = ProjectMetadata(
            title: "Project",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(detailProfile: .balanced),
            state: PipelineState(stage: .done, lastError: nil)
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: standardHardwareProfile,
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        try persistCompletedAppTestArtifacts(
            metadata: metadata,
            paths: paths,
            trainingArtifact: makeCompletedTrainingArtifact(
                for: paths.outputSplatURL,
                metadata: metadata
            )
        )

        let runner = ResumeRecordingPipelineRunner(projectURL: projectURL)
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile
        ) { _, _ in
            runner
        }

        XCTAssertTrue(model.retrainProject(at: projectURL, profile: .balanced))
        try await waitForViewState(model: model, state: .viewer)

        XCTAssertEqual(
            runner.resumeFrom,
            .sfmMapping,
            "A same-profile retrain must regenerate private training output for a new publication."
        )
    }

    func testRetrainIsIgnoredWhileRunIsActive() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let firstURL = try makeProject(at: tempBase, name: "First", lastError: nil, withOutput: false)
        let secondURL = try makeProject(at: tempBase, name: "Second", lastError: nil, withOutput: true)
        var callCount = 0
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile
        ) { _, _ in
            callCount += 1
            return BlockingPipelineRunner()
        }

        model.resumeProject(at: firstURL)
        try await waitForViewState(model: model, state: .processing)
        try await waitForCurrentProjectURL(model: model, url: firstURL)
        let secondProfileBefore = try ProjectMetadataStore.load(
            from: ProjectPaths(root: secondURL).metadataURL
        ).requestedRunOptions.detailProfile

        XCTAssertFalse(model.retrainProject(at: secondURL, profile: .highDetail))
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(model.currentProjectURL, firstURL)
        let secondProfileAfter = try ProjectMetadataStore.load(
            from: ProjectPaths(root: secondURL).metadataURL
        ).requestedRunOptions.detailProfile
        XCTAssertEqual(secondProfileAfter, secondProfileBefore)

        model.cancelCurrentProject(deleteProject: false)
        try await waitForViewState(model: model, state: .home, timeout: 4.0)
        XCTAssertFalse(model.isRunActive)
    }

    func testRetrainLeavesMetadataByteIdenticalWhenAnotherProcessOwnsRunLease() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(
            at: tempBase,
            withIntermediateDirectories: true
        )
        let projectURL = try makeProject(
            at: tempBase,
            name: "Busy Retrain",
            lastError: nil,
            withOutput: true
        )
        let paths = ProjectPaths(root: projectURL)
        let bytesBefore = try Data(contentsOf: paths.metadataURL)
        let externalLease = try ProjectRunLease.acquire(projectURL: projectURL)
        defer { externalLease.release() }
        var runnerFactoryCallCount = 0
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile
        ) { projectURL, config in
            runnerFactoryCallCount += 1
            return MockPipelineRunner(projectURL: projectURL, config: config)
        }

        XCTAssertFalse(
            model.retrainProject(at: projectURL, profile: .highDetail)
        )

        XCTAssertEqual(try Data(contentsOf: paths.metadataURL), bytesBefore)
        XCTAssertEqual(runnerFactoryCallCount, 0)
        XCTAssertFalse(model.isRunActive)
        XCTAssertEqual(model.statusTitle, "This project is already being processed.")
    }

    func testRetrainReleasesRunLeaseWhenMetadataMutationFailsBeforeTaskStarts() throws {
        enum MutationFailure: Error {
            case injected
        }

        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(
            at: tempBase,
            withIntermediateDirectories: true
        )
        let projectURL = try makeProject(
            at: tempBase,
            name: "Mutation Failure",
            lastError: nil,
            withOutput: true
        )
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile,
            pipelineRunnerFactory: { projectURL, config in
                MockPipelineRunner(projectURL: projectURL, config: config)
            },
            projectMetadataUpdater: { _, _ in
                throw MutationFailure.injected
            }
        )

        XCTAssertFalse(
            model.retrainProject(at: projectURL, profile: .highDetail)
        )
        XCTAssertNil(model.currentTask)
        XCTAssertFalse(model.isRunActive)

        let reacquiredLease = try ProjectRunLease.acquire(
            projectURL: projectURL
        )
        reacquiredLease.release()
    }

    func testRecoveryRetryReleasesRunLeaseWhenMetadataMutationFailsBeforeTaskStarts() throws {
        enum MutationFailure: Error {
            case injected
        }

        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(
            at: tempBase,
            withIntermediateDirectories: true
        )
        let projectURL = try makeProject(
            at: tempBase,
            name: "Recovery Mutation Failure",
            lastError: "Training failed",
            withOutput: false,
            stage: .trainSplat
        )
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile,
            pipelineRunnerFactory: { projectURL, config in
                MockPipelineRunner(projectURL: projectURL, config: config)
            },
            projectMetadataUpdater: { _, _ in
                throw MutationFailure.injected
            }
        )
        model.currentProjectURL = projectURL
        model.validationRecovery = .useBalanced
        model.failureRetryAllowed = true

        model.retryAfterFailure()

        XCTAssertNil(model.currentTask)
        XCTAssertFalse(model.isRunActive)
        XCTAssertEqual(model.validationRecovery, .useBalanced)
        let reacquiredLease = try ProjectRunLease.acquire(
            projectURL: projectURL
        )
        reacquiredLease.release()
    }

    func testResumeTaskReleasesSuppliedLeaseWhenTokenIsAlreadyStale() async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(
            at: tempBase,
            withIntermediateDirectories: true
        )
        let projectURL = try makeProject(
            at: tempBase,
            name: "Stale Resume Token",
            lastError: nil,
            withOutput: false,
            stage: .sfmMapping
        )
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase
        )
        let owner = try AppProjectRunLeaseOwner(
            projectURL: projectURL,
            acquire: model.projectRunLeaseOwnerAcquirer
        )
        model.currentTaskToken = UUID()

        await model.resumeProjectTask(
            at: projectURL,
            taskToken: UUID(),
            projectRunLeaseOwner: owner
        )

        let reacquiredLease = try ProjectRunLease.acquire(
            projectURL: projectURL
        )
        reacquiredLease.release()
    }

    func testLoadPipelineLogTailWithInvalidUtf8() throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()

        var logData = Data([0xF0, 0x9F])
        logData.append(contentsOf: "Hello log\n".utf8)
        try logData.write(to: paths.pipelineLogURL, options: [.atomic])

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        let lines = model.test_loadPipelineLogTail(projectURL: projectURL)
        XCTAssertTrue(lines.contains { $0.contains("Hello log") })
    }

    func testLoadPipelineLogTailKeepsNativeTrainerMessages() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let message = "[training model] completed loading native checkpoint"
        try (message + "\n").write(to: paths.pipelineLogURL, atomically: true, encoding: .utf8)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        XCTAssertEqual(model.test_loadPipelineLogTail(projectURL: projectURL), [message])
    }

    /// When the tail seek lands inside a multibyte UTF-8 sequence, we should drop the
    /// partial leading bytes (and the partial line that contained them) rather than
    /// emitting replacement characters in the first surviving line.
    func testLoadPipelineLogTailSkipsPartialFirstLineAtBoundary() throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()

        // Pad past the tail window so the seek lands inside this leading line, mid-emoji.
        // U+1F4A1 (light bulb) is a 4-byte sequence "F0 9F 92 A1" — a great victim for a mid-byte seek.
        var logData = Data()
        logData.append(contentsOf: String(repeating: "x", count: 200).utf8)
        logData.append(contentsOf: "💡 lead-in to be sliced\n".utf8)
        for index in 0..<10 {
            logData.append(contentsOf: "[stage] tail entry \(index)\n".utf8)
        }
        try logData.write(to: paths.pipelineLogURL, options: [.atomic])

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        // Tail window deliberately smaller than the leading "x"-padding so the seek lands inside.
        let lines = model.test_loadPipelineLogTail(projectURL: projectURL, maxLines: 100, maxBytes: 150)

        // The partial first line is dropped entirely — no Unicode replacement chars survive.
        for line in lines {
            XCTAssertFalse(line.contains("\u{FFFD}"), "tail emitted a replacement char in: \(line)")
            XCTAssertFalse(line.contains("lead-in to be sliced"), "tail kept a partial leading line: \(line)")
        }
        // The whole tail entries that came after the boundary are still present.
        XCTAssertTrue(lines.contains { $0.contains("tail entry 9") }, "expected last tail line; got \(lines)")
    }

    func testLoadPipelineLogTailRejectsSymlinkWithoutReadingExternalContents() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let marker = "external-app-symlink-log-secret"
        let outsideLog = tempBase.appendingPathComponent("outside.log")
        try marker.write(to: outsideLog, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: paths.pipelineLogURL, withDestinationURL: outsideLog)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        let lines = model.test_loadPipelineLogTail(projectURL: projectURL)

        XCTAssertTrue(lines.isEmpty)
        XCTAssertFalse(lines.joined(separator: "\n").contains(marker))
        XCTAssertEqual(try String(contentsOf: outsideLog, encoding: .utf8), marker)
    }

    func testLoadPipelineLogTailRejectsSymlinkedLogsDirectory() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try FileManager.default.removeItem(at: paths.logsURL)
        let outsideLogs = tempBase.appendingPathComponent("OutsideLogs", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideLogs, withIntermediateDirectories: true)
        let marker = "external-app-parent-symlink-log-secret"
        try marker.write(
            to: outsideLogs.appendingPathComponent("pipeline.log"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(
            at: paths.logsURL,
            withDestinationURL: outsideLogs
        )
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        let lines = model.test_loadPipelineLogTail(projectURL: projectURL)

        XCTAssertTrue(lines.isEmpty)
        XCTAssertFalse(lines.joined(separator: "\n").contains(marker))
    }

    func testLoadPipelineLogTailRejectsMultiplyLinkedFileWithoutReadingExternalContents() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let marker = "external-app-hardlink-log-secret"
        let outsideLog = tempBase.appendingPathComponent("outside.log")
        try marker.write(to: outsideLog, atomically: true, encoding: .utf8)
        try FileManager.default.linkItem(at: outsideLog, to: paths.pipelineLogURL)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        let lines = model.test_loadPipelineLogTail(projectURL: projectURL)

        XCTAssertTrue(lines.isEmpty)
        XCTAssertFalse(lines.joined(separator: "\n").contains(marker))
        XCTAssertEqual(try String(contentsOf: outsideLog, encoding: .utf8), marker)
    }

    func testLoadPipelineLogTailRejectsFIFO() throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        XCTAssertEqual(Darwin.mkfifo(paths.pipelineLogURL.path, mode_t(S_IRUSR | S_IWUSR)), 0)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        let lines = model.test_loadPipelineLogTail(projectURL: projectURL)

        XCTAssertTrue(lines.isEmpty)
    }

    func testRefreshProjectSummariesStatusMapping() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let readyURL = try makeProject(at: base, name: "Ready", lastError: nil, withOutput: true)
        _ = readyURL
        let failedURL = try makeProject(at: base, name: "Failed", lastError: "boom", withOutput: false)
        _ = failedURL
        let inProgressURL = try makeProject(
            at: base,
            name: "Progress",
            lastError: nil,
            withOutput: false,
            stage: .sfmMapping
        )
        _ = inProgressURL

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: base, config: config)
        }
        model.refreshProjectSummaries()

        let statusByTitle = Dictionary(model.projectSummaries.map { ($0.title, $0.status) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(statusByTitle["Ready"], .ready)
        XCTAssertEqual(statusByTitle["Failed"], .failed)
        XCTAssertEqual(statusByTitle["Progress"], .inProgress)
    }

    func testRefreshProjectSummariesPreservesRunStartAndFailureActivity() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = base.appendingPathComponent("RecentFailure.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let startedAt = Date(timeIntervalSince1970: 300)
        let failedAt = Date(timeIntervalSince1970: 400)
        try ProjectMetadataStore.save(
            ProjectMetadata(
                createdAt: Date(timeIntervalSince1970: 100),
                title: "Recent Failure",
                input: .video(files: []),
                state: PipelineState(stage: .sfmMapping, lastError: "boom"),
                lastRunStartedAt: startedAt,
                lastFailureAt: failedAt
            ),
            to: paths.metadataURL
        )
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)

        model.refreshProjectSummaries()

        let summary = try XCTUnwrap(model.projectSummaries.first)
        XCTAssertEqual(summary.lastRunStartedAt, startedAt)
        XCTAssertEqual(summary.lastFailureAt, failedAt)
        XCTAssertEqual(summary.lastActivityAt, failedAt)
    }

    func testBackgroundProjectSummaryRefreshPublishesProjectLibrarySnapshot() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base)
        _ = try makeProject(
            at: base,
            name: "Background Refresh",
            lastError: "capture failed",
            withOutput: false
        )

        model.refreshProjectSummariesInBackground()

        let deadline = Date().addingTimeInterval(2)
        while model.projectSummaries.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.projectSummaries.map(\.title), ["Background Refresh"])
    }

    func testRefreshProjectSummariesAndProjectActionsRejectSymlinkedBundle() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let base = parent.appendingPathComponent("Projects", isDirectory: true)
        let outsideProject = parent.appendingPathComponent("Outside.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideProject, withIntermediateDirectories: true)
        let outsidePaths = ProjectPaths(root: outsideProject)
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Outside",
                input: .video(files: []),
                requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
            ),
            to: outsidePaths.metadataURL
        )
        let originalMetadataBytes = try Data(contentsOf: outsidePaths.metadataURL)
        let linkedProject = base.appendingPathComponent("Linked.easysplatproj", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedProject,
            withDestinationURL: outsideProject
        )

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: linkedProject, config: config)
        }
        model.refreshProjectSummaries()
        XCTAssertTrue(model.projectSummaries.isEmpty)
        XCTAssertFalse(model.updateProjectNotes(at: linkedProject, to: "must stay local"))
        XCTAssertFalse(model.renameProject(at: linkedProject, to: "Must stay local"))
        model.markProjectOpened(at: linkedProject)

        XCTAssertEqual(try Data(contentsOf: outsidePaths.metadataURL), originalMetadataBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outsidePaths.lastOpenedSidecarURL.path))
    }

    func testRefreshProjectSummariesLoadsOnlyCurrentFormatWithoutMutatingSkippedBundles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        _ = try makeProject(
            at: base,
            name: "Current",
            lastError: "capture failed",
            withOutput: false
        )
        let baselineFormat = """
        {
          "formatVersion": \(ProjectMetadataStore.supportedFormatVersion - 1),
          "geometryArtifact": {
            "schemaVersion": \(GeometryArtifact.currentSchemaVersion - 1),
            "canonicalOrientation": {"status": "notEvaluated"}
          }
        }
        """
        let futureFormat = """
        {
          "formatVersion": \(ProjectMetadataStore.supportedFormatVersion + 1),
          "renamedField": 42
        }
        """
        let skipped = try [
            makeSkippedProject(at: base, name: "Baseline", metadata: baselineFormat),
            makeSkippedProject(at: base, name: "Future", metadata: futureFormat),
            makeSkippedProject(at: base, name: "Corrupt", metadata: "{not-json")
        ]
        let fileBundle = base.appendingPathComponent("NotADirectory.easysplatproj")
        try Data("leave this file alone".utf8).write(to: fileBundle)
        let fileBundleBytes = try Data(contentsOf: fileBundle)
        let fileBundleDate = try modificationDate(of: fileBundle)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: base, config: config)
        }
        model.refreshProjectSummaries()

        XCTAssertEqual(model.projectSummaries.map(\.title), ["Current"])
        try assertSkippedProjectsUnchanged(skipped)
        XCTAssertEqual(try Data(contentsOf: fileBundle), fileBundleBytes)
        XCTAssertEqual(try modificationDate(of: fileBundle), fileBundleDate)
    }

    func testBackgroundProjectSummaryRefreshIgnoresNoncurrentBundlesWithoutMutation() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        _ = try makeProject(
            at: base,
            name: "Current Background",
            lastError: "capture failed",
            withOutput: false
        )
        let baselineFormat = """
        {
          "formatVersion": \(ProjectMetadataStore.supportedFormatVersion - 1),
          "geometryArtifact": {
            "schemaVersion": \(GeometryArtifact.currentSchemaVersion - 1),
            "canonicalOrientation": {"status": "notEvaluated"}
          }
        }
        """
        let futureFormat = """
        {"formatVersion": \(ProjectMetadataStore.supportedFormatVersion + 1)}
        """
        let skipped = try [
            makeSkippedProject(at: base, name: "Baseline Background", metadata: baselineFormat),
            makeSkippedProject(at: base, name: "Future Background", metadata: futureFormat)
        ]

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: base, config: config)
        }
        model.refreshProjectSummariesInBackground()

        let deadline = Date().addingTimeInterval(2)
        while model.projectSummaries.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(model.projectSummaries.map(\.title), ["Current Background"])
        try assertSkippedProjectsUnchanged(skipped)
    }

    func testRefreshProjectSummariesDoesNotMarkOutputDirectoryReady() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = base.appendingPathComponent("DirectoryOutput.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(
            at: paths.outputURL.appendingPathComponent("splat.ply", isDirectory: true),
            withIntermediateDirectories: true
        )
        let metadata = ProjectMetadata(
            title: "DirectoryOutput",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            state: PipelineState(stage: .done, lastError: nil)
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: base, config: config)
        }
        model.refreshProjectSummaries()

        XCTAssertEqual(model.projectSummaries.first?.status, .failed)
    }

    func testRefreshProjectSummariesDoesNotMarkCorruptOutputReady() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = base.appendingPathComponent("CorruptOutput.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try "ply".write(to: paths.outputURL.appendingPathComponent("splat.ply"), atomically: true, encoding: .utf8)
        let metadata = ProjectMetadata(
            title: "CorruptOutput",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            state: PipelineState(stage: .done, lastError: nil)
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: base, config: config)
        }
        model.refreshProjectSummaries()

        XCTAssertEqual(model.projectSummaries.first?.status, .failed)
        XCTAssertNil(model.readyOutputURL(projectURL: projectURL, validationDepth: .quick))
    }

    func testRefreshProjectSummariesDoesNotMarkBarePlyReady() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = base.appendingPathComponent("BareOutput.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try writeMinimalPly(at: paths.outputURL.appendingPathComponent("splat.ply"))
        let metadata = ProjectMetadata(
            title: "Bare Output",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            state: PipelineState(stage: .done, lastError: nil)
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: base, config: config)
        }
        model.refreshProjectSummaries()

        XCTAssertEqual(model.projectSummaries.first?.status, .failed)
        XCTAssertNil(model.readyOutputURL(projectURL: projectURL, validationDepth: .quick))
        XCTAssertNil(model.readyOutputURL(projectURL: projectURL, validationDepth: .full))
    }

    func testRefreshProjectSummariesDoesNotDeepScanLargeAsciiOutput() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = base.appendingPathComponent("LargeAsciiOutput.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let largeDeclaredOutput = """
        ply
        format ascii 1.0
        element vertex 1000000
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
        0 0 0 1 1 1 -4 -4 -4 1 1 0 0 0
        """
        try writeMinimalPly(at: paths.outputSplatURL)
        let metadata = ProjectMetadata(
            title: "LargeAsciiOutput",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            state: PipelineState(stage: .done, lastError: nil)
        )
        let trainingArtifact = try makeCompletedTrainingArtifact(
            for: paths.outputURL.appendingPathComponent("splat.ply"),
            metadata: metadata,
            sceneBounds: SplatSceneBounds(
                center: ScenePoint3D(x: 0, y: 0, z: 0),
                radius: 3 * Foundation.exp(-4.0)
            )
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        try persistCompletedAppTestArtifacts(
            metadata: metadata,
            paths: paths,
            trainingArtifact: trainingArtifact
        )
        try largeDeclaredOutput.write(
            to: paths.outputSplatURL,
            atomically: true,
            encoding: .utf8
        )

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: base, config: config)
        }
        model.refreshProjectSummaries()

        XCTAssertEqual(model.projectSummaries.first?.status, .ready)
        XCTAssertEqual(
            model.readyOutputURL(projectURL: projectURL, validationDepth: .quick)?.lastPathComponent,
            "splat.ply"
        )
    }

    func testRefreshProjectSummariesRejectsEscapingTrainingOutputPath() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = base.appendingPathComponent("EscapingOutput.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let outside = base.appendingPathComponent("outside.ply")
        try writeMinimalPly(at: outside)
        try writeMinimalPly(at: paths.outputSplatURL)
        var metadata = ProjectMetadata(
            title: "EscapingOutput",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            state: PipelineState(stage: .done, lastError: nil)
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        var artifact = try makeCompletedTrainingArtifact(
            for: paths.outputSplatURL,
            metadata: metadata
        )
        artifact.outputPath = "../outside.ply"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: paths.metadataURL, options: .atomic)
        try encoder.encode(artifact).write(to: paths.trainingManifestURL, options: .atomic)
        XCTAssertThrowsError(try ProjectArtifactSnapshotStore.load(projectURL: projectURL))

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: base, config: config)
        }
        model.refreshProjectSummaries()

        XCTAssertEqual(model.projectSummaries.map(\.status), [.failed])
        XCTAssertNil(model.readyOutputURL(projectURL: projectURL, validationDepth: .quick))
    }

    func testStoppingKeptProjectRemainsUnfinishedAcrossRelaunch() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projectURL = try makeProject(
            at: base,
            name: "InterruptedReturn",
            lastError: nil,
            withOutput: false,
            checkpoint: PipelineCheckpoint(
                stage: .trainSplat,
                updatedAt: Date(),
                progressFraction: 0.5,
                message: "heartbeat",
                details: nil
            ),
            stage: .trainSplat
        )

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, _ in
            BlockingPipelineRunner()
        }

        model.resumeProject(at: projectURL)
        try await waitForViewState(model: model, state: .processing)

        model.cancelCurrentProject(deleteProject: false)
        try await waitForViewState(model: model, state: .home, timeout: 4.0)
        model.refreshProjectSummaries()

        XCTAssertTrue(FileManager.default.fileExists(atPath: projectURL.path))

        let relaunched = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }
        relaunched.refreshProjectSummaries()
        let stoppedSummary = relaunched.projectSummaries.first { $0.title == "InterruptedReturn" }
        XCTAssertNotNil(stoppedSummary, "Stopped project should remain listed.")
        XCTAssertEqual(stoppedSummary?.status, .inProgress)
        XCTAssertEqual(stoppedSummary?.isInterrupted, true)
    }

    func testForcedWindowCloseKeepsBypassUntilDelegateConsumesIt() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false

        model.stopAction = .keepProject
        model.exitIntent = .closeWindow
        model.pendingCloseWindow = window

        model.forceFinalizeExit(intent: .closeWindow, window: window)

        XCTAssertTrue(model.allowNextWindowClose)
        XCTAssertTrue(model.pendingCloseWindow === window)
        XCTAssertEqual(model.exitIntent, .closeWindow)
        XCTAssertTrue(model.consumeWindowCloseBypass(for: window))
        XCTAssertFalse(model.allowNextWindowClose)
        XCTAssertNil(model.pendingCloseWindow)
        XCTAssertEqual(model.exitIntent, .none)
    }

    func testFailedProcessingScreenDoesNotBlockApplicationTermination() {
        let model = AppModel(toolchainManager: MockToolchainManager())
        model.viewState = .processing
        model.lastError = "Capture needs more overlap."
        let delegate = AppDelegate(model: model)

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }

    func testAppTerminatesAfterItsOnlyWindowCloses() {
        let delegate = AppDelegate()

        XCTAssertTrue(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    func testAppKitWindowHostsTheSwiftUIWorkspace() {
        let model = AppModel(toolchainManager: MockToolchainManager())
        let delegate = AppDelegate(model: model)

        let window = delegate.makeMainWindow()

        XCTAssertEqual(window.title, "EasySplat")
        XCTAssertEqual(window.minSize, NSSize(width: 920, height: 640))
        XCTAssertGreaterThanOrEqual(window.frame.width, 920)
        XCTAssertGreaterThanOrEqual(window.frame.height, 640)
        XCTAssertTrue(window.contentViewController is NSHostingController<AppRootView>)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertFalse(window.isRestorable)
        XCTAssertEqual(window.tabbingMode, .disallowed)
    }

    func testFailedProcessingScreenDoesNotBlockWindowClose() {
        let model = AppModel(toolchainManager: MockToolchainManager())
        model.viewState = .processing
        model.lastError = "Capture needs more overlap."
        let coordinator = WindowAccessor.Coordinator(model: model)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        XCTAssertTrue(coordinator.windowShouldClose(window))
    }

    func testAppConfigUsesBundledAuthorityWhenDevelopmentOverridesAreForbidden() throws {
        let environment = [
            "EASYSPLAT_PROJECT_HOME_URL": "https://release-verifier-poison.invalid/project",
            "EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": "/release-verifier-poison/toolchain",
            "EASYSPLAT_SKIP_TRAINING": "1",
            "EASYSPLAT_STOP_AFTER_STAGE": PipelineStage.sfmMapping.rawValue,
            "EASYSPLAT_CANDIDATE_ROUTE": "da3",
            "EASYSPLAT_BENCHMARK_SEED": "2147483647",
        ]

        XCTAssertEqual(
            AppConfig.resolvedProjectHomeURL(
                environment: environment,
                allowsDevelopmentOverrides: false
            ).absoluteString,
            "https://github.com/dud8/EasySplat"
        )
        XCTAssertEqual(
            AppConfig.developmentOverrides(
                environment: environment,
                allowsDevelopmentOverrides: false
            ),
            .none
        )
    }

    func testAppConfigAllowsAuthorityOverridesForDevelopmentLaunches() {
        let environment = [
            "EASYSPLAT_PROJECT_HOME_URL": "https://example.com/project-home",
        ]

        XCTAssertEqual(
            AppConfig.resolvedProjectHomeURL(
                environment: environment,
                allowsDevelopmentOverrides: true
            ).absoluteString,
            "https://example.com/project-home"
        )
    }

    func testAppConfigGatesTypedDevelopmentOverrides() {
        let environment = [
            "EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": "/private/tmp/easysplat-toolchain",
            "EASYSPLAT_CANDIDATE_ROUTE": "colmap",
            "EASYSPLAT_STOP_AFTER_STAGE": PipelineStage.sfmMapping.rawValue,
            "EASYSPLAT_SKIP_TRAINING": "1",
            "EASYSPLAT_BENCHMARK_SEED": "57",
        ]

        XCTAssertEqual(
            AppConfig.developmentOverrides(
                environment: environment,
                allowsDevelopmentOverrides: false
            ),
            .none
        )
        XCTAssertEqual(
            AppConfig.developmentOverrides(
                environment: environment,
                allowsDevelopmentOverrides: true
            ),
            DevelopmentOverrides(
                localToolchainRoot: URL(
                    fileURLWithPath: "/private/tmp/easysplat-toolchain",
                    isDirectory: true
                ),
                candidateRoute: .colmap,
                stopAfterStage: .sfmMapping,
                skipTraining: true,
                benchmarkSeed: 57
            )
        )
    }

    func testCompiledDevelopmentOverridePolicyMatchesBuildConfiguration() {
#if DEBUG
        XCTAssertTrue(AppConfig.allowsDevelopmentOverrides)
#else
        XCTAssertFalse(AppConfig.allowsDevelopmentOverrides)
#endif
    }

    func testReleaseVerificationInputRejectsLegacyPositionalGate() throws {
        let isolatedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fixedHome = isolatedRoot.appendingPathComponent("ReleaseVerificationHome", isDirectory: true)
        let input = isolatedRoot.appendingPathComponent("ReleaseVerificationInput", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: isolatedRoot) }
        try FileManager.default.createDirectory(at: fixedHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let photos = input.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let manifest = input.appendingPathComponent("release-input-manifest.json")
        try Data(
            #"{"photoFolder":"Photos","schemaVersion":1,"videos":[]}"#.utf8
        ).write(to: manifest)
        let environment = [
            "HOME": fixedHome.path,
            "CFFIXED_USER_HOME": fixedHome.path,
            "EASYSPLAT_ISOLATED_UI_RUNNER": "1",
            "EASYSPLAT_RELEASE_VERIFY_TOKEN": "easysplat-release-verify-12345678-1234-4ABC-9DEF-1234567890AB",
        ]
        let legacyArguments = [
            "/Applications/EasySplat.app/Contents/MacOS/EasySplatApp",
            "--easysplat-release-verify-bundled-pipeline",
            input.path,
        ]

        XCTAssertNil(AppConfig.releaseVerificationConfiguration(
            environment: environment,
            arguments: legacyArguments
        ))
        let video = input.appendingPathComponent("release-input.mp4")
        try Data("video fixture".utf8).write(to: video)
        XCTAssertNil(AppConfig.releaseVerificationConfiguration(
            environment: environment,
            arguments: [legacyArguments[0], legacyArguments[1], video.path]
        ))

        var missingRunner = environment
        missingRunner.removeValue(forKey: "EASYSPLAT_ISOLATED_UI_RUNNER")
        XCTAssertNil(AppConfig.releaseVerificationConfiguration(
            environment: missingRunner,
            arguments: legacyArguments
        ))
        XCTAssertNil(AppConfig.releaseVerificationConfiguration(
            environment: environment,
            arguments: [legacyArguments[0], input.path]
        ))

        for invalidToken in [
            "",
            "12345678-1234-4abc-9def-1234567890ab",
            "easysplat-release-verify-1234567812344abc9def1234567890ab",
            "easysplat-release-verify-not-a-uuid",
            "easysplat-release-verify-12345678-1234-4abc-7def-1234567890ab-extra",
        ] {
            XCTAssertNil(AppConfig.releaseVerificationConfiguration(
                environment: environment.merging([
                    "EASYSPLAT_RELEASE_VERIFY_TOKEN": invalidToken,
                ]) { _, new in new },
                arguments: legacyArguments
            ))
        }
    }

    func testReleaseVerificationConfigurationAcceptsOnlyStrictIsolatedManifestGate() throws {
        let isolatedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fixedHome = isolatedRoot.appendingPathComponent(
            "ReleaseVerificationHome",
            isDirectory: true
        )
        let inputRoot = isolatedRoot.appendingPathComponent(
            "ReleaseVerificationInput",
            isDirectory: true
        )
        let videos = inputRoot.appendingPathComponent("Videos", isDirectory: true)
        let photos = inputRoot.appendingPathComponent("Photos", isDirectory: true)
        let manifest = inputRoot.appendingPathComponent("release-input-manifest.json")
        defer { try? FileManager.default.removeItem(at: isolatedRoot) }
        try FileManager.default.createDirectory(at: fixedHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: videos.appendingPathComponent("first.mov"))
        try Data("second".utf8).write(to: videos.appendingPathComponent("second.mov"))
        try Data(
            #"{"photoFolder":"Photos","schemaVersion":1,"videos":["Videos/first.mov","Videos/second.mov"]}"#.utf8
        ).write(to: manifest)
        let environment = [
            "HOME": fixedHome.path,
            "CFFIXED_USER_HOME": fixedHome.path,
            "EASYSPLAT_ISOLATED_UI_RUNNER": "1",
            "EASYSPLAT_RELEASE_VERIFY_TOKEN":
                "easysplat-release-verify-12345678-1234-4abc-9def-1234567890ab",
        ]
        let executable = "/Applications/EasySplat.app/Contents/MacOS/EasySplatApp"
        let gate = "--easysplat-release-verify-bundled-pipeline"
        let arguments = [
            executable,
            gate,
            "--input-manifest",
            manifest.path,
            "--input-root",
            inputRoot.path,
        ]

        let configuration = try XCTUnwrap(AppConfig.releaseVerificationConfiguration(
            environment: environment,
            arguments: arguments
        ))
        XCTAssertEqual(configuration.inputManifestURL, manifest)
        XCTAssertEqual(configuration.inputRootURL, inputRoot)

        let alternateManifest = inputRoot.appendingPathComponent("alternate.json")
        try Data(contentsOf: manifest).write(to: alternateManifest)
        XCTAssertNil(AppConfig.releaseVerificationConfiguration(
            environment: environment,
            arguments: [
                executable,
                gate,
                "--input-manifest",
                alternateManifest.path,
                "--input-root",
                inputRoot.path,
            ]
        ))
        XCTAssertNil(AppConfig.releaseVerificationConfiguration(
            environment: environment,
            arguments: [executable, gate, "--input-manifest", manifest.path]
        ))
    }

    func testOrdinaryStartupUsesRegularActivationPolicy() {
        XCTAssertEqual(
            AppConfig.releaseVerificationStartup(
                environment: [:],
                arguments: ["/Applications/EasySplat.app/Contents/MacOS/EasySplatApp"]
            ),
            .ordinary
        )
        XCTAssertEqual(
            EasySplatApplication.activationPolicy(for: .ordinary),
            .regular
        )
    }

    func testOrdinaryDevelopmentOverridesDoNotTriggerReleaseVerification() {
        let executable = "/Applications/EasySplat.app/Contents/MacOS/EasySplatApp"
        let ordinaryOverrides = [
            ("EASYSPLAT_SKIP_TRAINING", "1"),
            ("EASYSPLAT_STOP_AFTER_STAGE", PipelineStage.sfmMapping.rawValue),
            ("EASYSPLAT_CANDIDATE_ROUTE", "da3"),
            ("EASYSPLAT_BENCHMARK_SEED", "2147483647"),
        ]

        for (key, value) in ordinaryOverrides {
            let startup = AppConfig.releaseVerificationStartup(
                environment: [key: value],
                arguments: [executable]
            )
            XCTAssertEqual(startup, .ordinary, "\(key) is a normal development override")
            XCTAssertFalse(startup.requiresImmediateExit)
        }
    }

    func testMalformedReleaseVerificationAttemptFailsClosedBeforeAppKit() {
        let executable = "/Applications/EasySplat.app/Contents/MacOS/EasySplatApp"
        let gate = "--easysplat-release-verify-bundled-pipeline"
        let malformedAttempts: [([String: String], [String])] = [
            ([:], [executable, gate]),
            (["EASYSPLAT_RELEASE_VERIFY_TOKEN": ""], [executable]),
            ([:], [executable, "--easysplat-release-verify-invalid"]),
            ([
                "EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": "/release-verifier-poison/toolchain",
            ], [executable]),
        ]

        for (environment, arguments) in malformedAttempts {
            let startup = AppConfig.releaseVerificationStartup(
                environment: environment,
                arguments: arguments
            )
            XCTAssertEqual(startup, .rejected)
            XCTAssertTrue(startup.requiresImmediateExit)
            XCTAssertEqual(
                EasySplatApplication.activationPolicy(for: startup),
                .prohibited
            )
        }
    }

    func testAuthenticatedReleaseVerificationStartupProhibitsGUIActivation() {
        let configuration = AppConfig.ReleaseVerificationConfiguration(
            inputManifestURL: URL(fileURLWithPath: "/private/tmp/release-input-manifest.json"),
            inputRootURL: URL(fileURLWithPath: "/private/tmp/ReleaseVerificationInput"),
            successMarkerURL: URL(fileURLWithPath: "/private/tmp/release-verification-passed.json"),
            verificationToken: "easysplat-release-verify-12345678-1234-4abc-9def-1234567890ab"
        )

        XCTAssertEqual(
            EasySplatApplication.activationPolicy(for: .authorized(configuration)),
            .prohibited
        )
    }

    func testReleaseVerificationInputRejectsNonisolatedAndOverrideInputs() throws {
        let isolatedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fixedHome = isolatedRoot.appendingPathComponent("ReleaseVerificationHome", isDirectory: true)
        let input = isolatedRoot.appendingPathComponent("ReleaseVerificationInput", isDirectory: true)
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: isolatedRoot)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(at: fixedHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let photos = input.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let manifest = input.appendingPathComponent("release-input-manifest.json")
        try Data(
            #"{"photoFolder":"Photos","schemaVersion":1,"videos":[]}"#.utf8
        ).write(to: manifest)
        let validArguments = [
            "/Applications/EasySplat.app/Contents/MacOS/EasySplatApp",
            "--easysplat-release-verify-bundled-pipeline",
            "--input-manifest",
            manifest.path,
            "--input-root",
            input.path,
        ]
        let executable = "/Applications/EasySplat.app/Contents/MacOS/EasySplatApp"
        let gate = "--easysplat-release-verify-bundled-pipeline"
        let base = [
            "HOME": fixedHome.path,
            "CFFIXED_USER_HOME": fixedHome.path,
            "EASYSPLAT_ISOLATED_UI_RUNNER": "1",
            "EASYSPLAT_RELEASE_VERIFY_TOKEN": "easysplat-release-verify-12345678-1234-4abc-9def-1234567890ab",
        ]

        XCTAssertNil(AppConfig.releaseVerificationConfiguration(
            environment: base,
            arguments: [
                executable,
                gate,
                "--input-manifest",
                outside.appendingPathComponent("release-input-manifest.json").path,
                "--input-root",
                outside.path,
            ]
        ))
        XCTAssertNil(AppConfig.releaseVerificationConfiguration(
            environment: base.merging(["HOME": outside.path]) { _, new in new },
            arguments: validArguments
        ))
        for override in [
            "EASYSPLAT_PROJECT_HOME_URL",
            "EASYSPLAT_LOCAL_TOOLCHAIN_ROOT",
            "EASYSPLAT_SKIP_TRAINING",
            "EASYSPLAT_STOP_AFTER_STAGE",
            "EASYSPLAT_CANDIDATE_ROUTE",
            "EASYSPLAT_BENCHMARK_SEED",
        ] {
            XCTAssertNil(AppConfig.releaseVerificationConfiguration(
                environment: base.merging([override: "forbidden"]) { _, new in new },
                arguments: validArguments
            ))
        }
    }

    func testReleaseVerificationGateAcceptsOnlyFixedPoisonSentinels() throws {
        let isolatedRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fixedHome = isolatedRoot.appendingPathComponent("ReleaseVerificationHome", isDirectory: true)
        let input = isolatedRoot.appendingPathComponent("ReleaseVerificationInput", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: isolatedRoot) }
        try FileManager.default.createDirectory(at: fixedHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        let photos = input.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let manifest = input.appendingPathComponent("release-input-manifest.json")
        try Data(
            #"{"photoFolder":"Photos","schemaVersion":1,"videos":[]}"#.utf8
        ).write(to: manifest)
        let executable = "/Applications/EasySplat.app/Contents/MacOS/EasySplatApp"
        let gate = "--easysplat-release-verify-bundled-pipeline"
        let poison = [
            "EASYSPLAT_PROJECT_HOME_URL": "https://release-verifier-poison.invalid/project",
            "EASYSPLAT_LOCAL_TOOLCHAIN_ROOT": "/release-verifier-poison/toolchain",
            "EASYSPLAT_SKIP_TRAINING": "1",
            "EASYSPLAT_STOP_AFTER_STAGE": PipelineStage.sfmMapping.rawValue,
            "EASYSPLAT_CANDIDATE_ROUTE": "da3",
            "EASYSPLAT_BENCHMARK_SEED": "2147483647",
        ]
        let environment = poison.merging([
            "HOME": fixedHome.path,
            "CFFIXED_USER_HOME": fixedHome.path,
            "EASYSPLAT_ISOLATED_UI_RUNNER": "1",
            "EASYSPLAT_RELEASE_VERIFY_TOKEN": "easysplat-release-verify-12345678-1234-4abc-9def-1234567890ab",
        ]) { _, required in required }
        let arguments = [
            executable,
            gate,
            "--input-manifest",
            manifest.path,
            "--input-root",
            input.path,
        ]

        XCTAssertNotNil(AppConfig.releaseVerificationConfiguration(
            environment: environment,
            arguments: arguments
        ))
        for key in poison.keys {
            XCTAssertNil(
                AppConfig.releaseVerificationConfiguration(
                    environment: environment.merging([key: "forbidden"]) { _, value in value },
                    arguments: arguments
                ),
                "Release verification accepted an arbitrary value for \(key)."
            )
        }
    }

    func testReleaseVerificationRunsProductionProjectPipelineBeforeWritingMarker() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inputRoot = base.appendingPathComponent(
            "ReleaseVerificationInput",
            isDirectory: true
        )
        let photoFolder = inputRoot.appendingPathComponent("InputPhotos", isDirectory: true)
        let marker = base.appendingPathComponent("toolchain-ready.json")
        let executable = base.appendingPathComponent("EasySplatApp")
        let verificationToken = "easysplat-release-verify-12345678-1234-4abc-9def-1234567890ab"
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: photoFolder, withIntermediateDirectories: true)
        try Data("packaged executable fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        for (index, value) in [UInt8(20), 110, 220].enumerated() {
            XCTAssertTrue(try writeTestGrayscaleImage(
                at: photoFolder.appendingPathComponent("view-\(index).png"),
                value: value
            ))
        }
        let manager = CapabilityRecordingToolchainManager()
        var pipelineFactoryInvocations = 0
        var pipelineToolchainRoot: URL?
        let model = AppModel(
            toolchainManager: manager,
            projectBaseURL: base.appendingPathComponent("Projects", isDirectory: true),
            hardwareProfile: standardHardwareProfile
        ) { projectURL, config in
            pipelineFactoryInvocations += 1
            pipelineToolchainRoot = config.toolchain.root.standardizedFileURL
            return MockPipelineRunner(projectURL: projectURL, config: config)
        }

        try await model.runBundledPipelineForReleaseVerification(
            inputManifestURL: try releasePhotoInputManifest(
                    inputRoot: inputRoot,
                photoFolderName: photoFolder.lastPathComponent
            ),
                inputRootURL: inputRoot,
            successMarkerURL: marker,
            verificationToken: verificationToken,
            appVersion: "0.2.0-beta.1",
            executableURL: executable
        )

        XCTAssertEqual(manager.lastRequest?.capabilities, [.core, .colmap, .msplat])
        XCTAssertEqual(manager.requestCount, 1)
        XCTAssertEqual(pipelineFactoryInvocations, 1)
        let projectURL = try XCTUnwrap(model.currentProjectURL)
        let outputURL = try XCTUnwrap(model.outputPlyURL)
        XCTAssertEqual(model.viewState, .viewer)
        let revalidatedOutputURL = try await model.validatedFinishedOutputURL(
            projectURL: projectURL
        )
        XCTAssertEqual(
            revalidatedOutputURL,
            outputURL
        )
        XCTAssertFalse(model.isRunActive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let markerData = try Data(contentsOf: marker)
        let evidence = try JSONSerialization.jsonObject(with: markerData) as? [String: Any]
        XCTAssertEqual(evidence?["schemaVersion"] as? Int, 3)
        XCTAssertEqual(
            evidence?["releaseVerificationTokenSHA256"] as? String,
            "41adf8246687dd0d9b3c5e24fa907cc0beac06e940f7933ede615ddfc1037285"
        )
        XCTAssertNil(evidence?["verificationToken"])
        XCTAssertFalse(String(decoding: markerData, as: UTF8.self).contains(verificationToken))
        XCTAssertEqual(evidence?["appVersion"] as? String, "0.2.0-beta.1")
        XCTAssertEqual(evidence?["executablePath"] as? String, executable.standardizedFileURL.path)
        XCTAssertEqual(
            evidence?["executableBytes"] as? Int,
            try Data(contentsOf: executable).count
        )
        XCTAssertEqual(
            evidence?["executableSHA256"] as? String,
            try GeometryArtifactStore.sha256(of: executable)
        )
        XCTAssertEqual(evidence?["toolchainRoot"] as? String, pipelineToolchainRoot?.path)
        XCTAssertEqual(
            Set(evidence?["requestedCapabilities"] as? [String] ?? []),
            Set(["runtime.core", "geometry.colmap", "training.msplat"])
        )
        XCTAssertEqual(evidence?["inputPath"] as? String, inputRoot.standardizedFileURL.path)
        XCTAssertEqual(
            evidence?["inputManifestSHA256"] as? String,
            try GeometryArtifactStore.sha256(
                of: inputRoot.appendingPathComponent("release-input-manifest.json")
            )
        )
        XCTAssertEqual(evidence?["projectRoot"] as? String, projectURL.standardizedFileURL.path)
        XCTAssertEqual(evidence?["outputPlyPath"] as? String, outputURL.standardizedFileURL.path)
        XCTAssertEqual(evidence?["outputVertices"] as? Int, 1)
        XCTAssertEqual(evidence?["outputFormat"] as? String, "ascii")
        XCTAssertEqual(
            evidence?["outputBytes"] as? Int,
            try Data(contentsOf: outputURL).count
        )
        XCTAssertEqual(
            evidence?["outputSHA256"] as? String,
            try ProjectArtifactValidator.validatedPlyEvidence(at: outputURL).sha256
        )
        let markerAttributes = try FileManager.default.attributesOfItem(atPath: marker.path)
        XCTAssertEqual((markerAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testReleaseVerificationManifestRunsOrderedMixedInputAndBindsMarkerDigest() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inputRoot = base.appendingPathComponent("ReleaseVerificationInput", isDirectory: true)
        let videos = inputRoot.appendingPathComponent("Videos", isDirectory: true)
        let photos = inputRoot.appendingPathComponent("Photos", isDirectory: true)
        let manifest = inputRoot.appendingPathComponent("release-input-manifest.json")
        let marker = base.appendingPathComponent("toolchain-ready.json")
        let executable = base.appendingPathComponent("EasySplatApp")
        let verificationToken =
            "easysplat-release-verify-12345678-1234-4abc-9def-1234567890ab"
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let first = videos.appendingPathComponent("first.mov")
        let second = videos.appendingPathComponent("second.mov")
        try Data("first-video".utf8).write(to: first)
        try Data("second-video".utf8).write(to: second)
        for (index, value) in [UInt8(20), 110, 220].enumerated() {
            XCTAssertTrue(try writeTestGrayscaleImage(
                at: photos.appendingPathComponent("view-\(index).png"),
                value: value
            ))
        }
        let manifestData = Data(
            #"{"photoFolder":"Photos","schemaVersion":1,"videos":["Videos/first.mov","Videos/second.mov"]}"#.utf8
        )
        try manifestData.write(to: manifest)
        try Data("packaged executable fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        let model = AppModel(
            toolchainManager: CapabilityRecordingToolchainManager(),
            projectBaseURL: base.appendingPathComponent("Projects", isDirectory: true),
            hardwareProfile: standardHardwareProfile,
            videoInputPreflight: passingVideoPreflight()
        ) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        try await model.runBundledPipelineForReleaseVerification(
            inputManifestURL: manifest,
            inputRootURL: inputRoot,
            successMarkerURL: marker,
            verificationToken: verificationToken,
            appVersion: "0.2.0-beta.1",
            executableURL: executable
        )

        let markerData = try Data(contentsOf: marker)
        let evidence = try XCTUnwrap(
            JSONSerialization.jsonObject(with: markerData) as? [String: Any]
        )
        XCTAssertEqual(evidence.count, 16)
        XCTAssertEqual(evidence["schemaVersion"] as? Int, 3)
        XCTAssertEqual(evidence["inputPath"] as? String, inputRoot.standardizedFileURL.path)
        XCTAssertEqual(
            evidence["inputManifestSHA256"] as? String,
            try GeometryArtifactStore.sha256(of: manifest)
        )
        XCTAssertEqual(
            Set(evidence.keys),
            [
                "schemaVersion",
                "releaseVerificationTokenSHA256",
                "appVersion",
                "executablePath",
                "executableBytes",
                "executableSHA256",
                "toolchainRoot",
                "requestedCapabilities",
                "inputPath",
                "inputManifestSHA256",
                "projectRoot",
                "outputPlyPath",
                "outputBytes",
                "outputVertices",
                "outputFormat",
                "outputSHA256",
            ]
        )
        let projectURL = try XCTUnwrap(model.currentProjectURL)
        let metadata = try ProjectMetadataStore.load(
            from: ProjectPaths(root: projectURL).metadataURL
        )
        guard case .mixed(let controlledVideos, let controlledPhotos) = metadata.input else {
            return XCTFail("Expected a controlled mixed-input project")
        }
        XCTAssertEqual(metadata.videoInputReceipts?.map(\.safeDisplayName), [
            "first.mov",
            "second.mov",
        ])
        XCTAssertEqual(controlledVideos, [
            "Originals/video-0000.mov",
            "Originals/video-0001.mov",
        ])
        XCTAssertEqual(controlledPhotos, "Originals/Photos")
        let metadataText = String(
            decoding: try Data(contentsOf: ProjectPaths(root: projectURL).metadataURL),
            as: UTF8.self
        )
        XCTAssertFalse(metadataText.contains(inputRoot.path))
        XCTAssertFalse(metadataText.contains(manifest.path))
    }

    func testReleaseVerificationPipelineDoesNotWriteMarkerWhenToolValidationFails() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inputRoot = base.appendingPathComponent(
            "ReleaseVerificationInput",
            isDirectory: true
        )
        let photoFolder = inputRoot.appendingPathComponent("InputPhotos", isDirectory: true)
        let marker = base.appendingPathComponent("toolchain-ready.json")
        let executable = base.appendingPathComponent("EasySplatApp")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: photoFolder, withIntermediateDirectories: true)
        try Data("packaged executable fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        for (index, value) in [UInt8(20), 110, 220].enumerated() {
            XCTAssertTrue(try writeTestGrayscaleImage(
                at: photoFolder.appendingPathComponent("view-\(index).png"),
                value: value
            ))
        }
        let model = AppModel(
            toolchainManager: FailingToolchainManager(message: "validation failed"),
            projectBaseURL: base.appendingPathComponent("Projects", isDirectory: true),
            hardwareProfile: standardHardwareProfile
        ) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        do {
            try await model.runBundledPipelineForReleaseVerification(
                inputManifestURL: try releasePhotoInputManifest(
                    inputRoot: inputRoot,
                    photoFolderName: photoFolder.lastPathComponent
                ),
                inputRootURL: inputRoot,
                successMarkerURL: marker,
                verificationToken: "easysplat-release-verify-12345678-1234-4abc-9def-1234567890ab",
                appVersion: "0.2.0-beta.1",
                executableURL: executable
            )
            XCTFail("Expected release-verification pipeline to fail")
        } catch {
            XCTAssertEqual(error as? ReleaseVerificationRunError, .pipelineFailed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertNotNil(model.lastError)
    }

    func testReleaseVerificationDoesNotPublishMarkerAfterExecutableChanges() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inputRoot = base.appendingPathComponent(
            "ReleaseVerificationInput",
            isDirectory: true
        )
        let photoFolder = inputRoot.appendingPathComponent("InputPhotos", isDirectory: true)
        let marker = base.appendingPathComponent("toolchain-ready.json")
        let executable = base.appendingPathComponent("EasySplatApp")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: photoFolder, withIntermediateDirectories: true)
        for (index, value) in [UInt8(20), 110, 220].enumerated() {
            XCTAssertTrue(try writeTestGrayscaleImage(
                at: photoFolder.appendingPathComponent("view-\(index).png"),
                value: value
            ))
        }
        try Data("packaged executable fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let model = AppModel(
            toolchainManager: CapabilityRecordingToolchainManager(),
            projectBaseURL: base.appendingPathComponent("Projects", isDirectory: true),
            hardwareProfile: standardHardwareProfile
        ) { projectURL, config in
            ExecutableMutatingPipelineRunner(
                projectURL: projectURL,
                config: config,
                executableURL: executable
            )
        }

        do {
            try await model.runBundledPipelineForReleaseVerification(
                inputManifestURL: try releasePhotoInputManifest(
                    inputRoot: inputRoot,
                    photoFolderName: photoFolder.lastPathComponent
                ),
                inputRootURL: inputRoot,
                successMarkerURL: marker,
                verificationToken: "easysplat-release-verify-12345678-1234-4abc-9def-1234567890ab",
                appVersion: "0.2.0-beta.1",
                executableURL: executable
            )
            XCTFail("Expected executable mutation to invalidate release verification")
        } catch {
            XCTAssertEqual(error as? ReleaseVerificationRunError, .executableChanged)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testReleaseVerificationExecutableHashRejectsPathReplacementDuringDescriptorRead() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let executable = base.appendingPathComponent("EasySplatApp")
        let displaced = base.appendingPathComponent("EasySplatApp.original")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("original executable".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        XCTAssertThrowsError(try AppModel.releaseVerificationExecutableEvidence(
            at: executable,
            afterInitialDescriptorStatus: { _ in
                try FileManager.default.moveItem(at: executable, to: displaced)
                try Data("replacement executable".utf8).write(to: executable)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: executable.path
                )
            }
        )) { error in
            XCTAssertEqual(error as? ReleaseVerificationRunError, .executableChanged)
        }
    }

    func testReleaseVerificationRechecksExecutableAfterMarkerStagingBeforePublication() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inputRoot = base.appendingPathComponent(
            "ReleaseVerificationInput",
            isDirectory: true
        )
        let photoFolder = inputRoot.appendingPathComponent("InputPhotos", isDirectory: true)
        let marker = base.appendingPathComponent("toolchain-ready.json")
        let executable = base.appendingPathComponent("EasySplatApp")
        let displaced = base.appendingPathComponent("EasySplatApp.original")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: photoFolder, withIntermediateDirectories: true)
        for (index, value) in [UInt8(20), 110, 220].enumerated() {
            XCTAssertTrue(try writeTestGrayscaleImage(
                at: photoFolder.appendingPathComponent("view-\(index).png"),
                value: value
            ))
        }
        try Data("packaged executable fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let model = AppModel(
            toolchainManager: CapabilityRecordingToolchainManager(),
            projectBaseURL: base.appendingPathComponent("Projects", isDirectory: true),
            hardwareProfile: standardHardwareProfile
        ) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }
        var calls = ReleaseVerificationMarkerSystemCalls.system()
        let synchronize = calls.synchronize
        var replacedExecutable = false
        calls.synchronize = { descriptor in
            let result = synchronize(descriptor)
            if result == 0, !replacedExecutable {
                replacedExecutable = true
                try! FileManager.default.moveItem(at: executable, to: displaced)
                try! Data("replacement executable".utf8).write(to: executable)
                try! FileManager.default.setAttributes(
                    [.posixPermissions: 0o700],
                    ofItemAtPath: executable.path
                )
            }
            return result
        }

        do {
            try await model.runBundledPipelineForReleaseVerification(
                inputManifestURL: try releasePhotoInputManifest(
                    inputRoot: inputRoot,
                    photoFolderName: photoFolder.lastPathComponent
                ),
                inputRootURL: inputRoot,
                successMarkerURL: marker,
                verificationToken: "easysplat-release-verify-12345678-1234-4abc-9def-1234567890ab",
                appVersion: "0.2.0-beta.1",
                executableURL: executable,
                markerSystemCalls: calls
            )
            XCTFail("Expected marker-boundary executable replacement to fail")
        } catch {
            XCTAssertEqual(error as? ReleaseVerificationRunError, .executableChanged)
        }
        XCTAssertTrue(replacedExecutable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testReleaseVerificationMarkerRetriesInterruptedDirectorySyncOnOriginalDescriptor() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let marker = base.appendingPathComponent("toolchain-ready.json")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var calls = ReleaseVerificationMarkerSystemCalls.system()
        let liveSynchronize = calls.synchronize
        var synchronizedDescriptors: [Int32] = []
        calls.synchronize = { descriptor in
            synchronizedDescriptors.append(descriptor)
            if synchronizedDescriptors.count == 2 {
                errno = EINTR
                return -1
            }
            return liveSynchronize(descriptor)
        }

        try AppModel.writeReleaseVerificationMarker(
            Data("evidence".utf8),
            to: marker,
            systemCalls: calls
        )

        XCTAssertEqual(try Data(contentsOf: marker), Data("evidence".utf8))
        XCTAssertEqual(synchronizedDescriptors.count, 3)
        XCTAssertNotEqual(synchronizedDescriptors[0], synchronizedDescriptors[1])
        XCTAssertEqual(
            synchronizedDescriptors[1],
            synchronizedDescriptors[2],
            "The interrupted directory sync must retry the already-open directory descriptor."
        )
    }

    func testReleaseVerificationMarkerRejectsStagingMutationBeforePublication() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let marker = base.appendingPathComponent("toolchain-ready.json")

        XCTAssertThrowsError(try AppModel.writeReleaseVerificationMarker(
            Data("evidence".utf8),
            to: marker,
            validateBeforePublication: {
                let stagedName = try XCTUnwrap(
                    FileManager.default.contentsOfDirectory(atPath: base.path)
                        .first(where: { $0.hasPrefix(".release-verification-marker-") })
                )
                let staged = base.appendingPathComponent(stagedName)
                try Data("tampered".utf8).write(to: staged)
            }
        )) { error in
            XCTAssertEqual(
                error as? ReleaseVerificationMarkerError,
                .operationFailed(operation: "validate marker staging identity", errno: EIO)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path), [])
    }

    func testReleaseVerificationMarkerRejectsMutationImmediatelyAfterPublication() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let marker = base.appendingPathComponent("toolchain-ready.json")
        var calls = ReleaseVerificationMarkerSystemCalls.system()
        calls.afterPublicationRename = { descriptor in
            XCTAssertEqual(lseek(descriptor, 0, SEEK_SET), 0)
            let replacement = Data("tampered".utf8)
            replacement.withUnsafeBytes { bytes in
                XCTAssertEqual(write(descriptor, bytes.baseAddress, bytes.count), bytes.count)
            }
            XCTAssertEqual(fchmod(descriptor, mode_t(S_IRUSR)), 0)
        }

        XCTAssertThrowsError(try AppModel.writeReleaseVerificationMarker(
            Data("evidence".utf8),
            to: marker,
            systemCalls: calls
        )) { error in
            XCTAssertEqual(
                error as? ReleaseVerificationMarkerError,
                .operationFailed(
                    operation: "validate the marker immediately after publication",
                    errno: EIO
                )
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path), [])
    }

    func testReleaseVerificationMarkerRemovesRenamedDestinationWhenDirectorySyncFails() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let marker = base.appendingPathComponent("toolchain-ready.json")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var calls = ReleaseVerificationMarkerSystemCalls.system()
        let liveSynchronize = calls.synchronize
        var synchronizationAttempts = 0
        calls.synchronize = { descriptor in
            synchronizationAttempts += 1
            if synchronizationAttempts == 2 {
                errno = EIO
                return -1
            }
            return liveSynchronize(descriptor)
        }

        XCTAssertThrowsError(try AppModel.writeReleaseVerificationMarker(
            Data("evidence".utf8),
            to: marker,
            systemCalls: calls
        )) { error in
            XCTAssertEqual(
                error as? ReleaseVerificationMarkerError,
                .operationFailed(operation: "sync the marker directory", errno: EIO)
            )
        }

        XCTAssertEqual(synchronizationAttempts, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: base.path),
            []
        )
    }

    func testReleaseVerificationMarkerPreservesRacedReplacementDuringRollback() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let marker = base.appendingPathComponent("toolchain-ready.json")
        let replacement = base.appendingPathComponent("replacement.json")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: replacement)
        var calls = ReleaseVerificationMarkerSystemCalls.system()
        let liveSynchronize = calls.synchronize
        let liveRenameExclusively = calls.renameExclusively
        var synchronizationAttempts = 0
        var replacementWasInstalled = false
        calls.synchronize = { descriptor in
            synchronizationAttempts += 1
            if synchronizationAttempts == 2 {
                errno = EIO
                return -1
            }
            return liveSynchronize(descriptor)
        }
        calls.renameExclusively = { directory, source, destination in
            guard !replacementWasInstalled else {
                return liveRenameExclusively(directory, source, destination)
            }
            let renameResult = replacement.lastPathComponent.withCString { replacementName in
                source.withCString { sourceName in
                    renameat(directory, replacementName, directory, sourceName)
                }
            }
            guard renameResult == 0 else { return renameResult }
            replacementWasInstalled = true
            return liveRenameExclusively(directory, source, destination)
        }

        XCTAssertThrowsError(try AppModel.writeReleaseVerificationMarker(
            Data("evidence".utf8),
            to: marker,
            systemCalls: calls
        )) { error in
            XCTAssertEqual(
                error as? ReleaseVerificationMarkerError,
                .rollbackDestinationChanged
            )
            XCTAssertTrue(error.localizedDescription.contains("replacement was preserved"))
        }

        XCTAssertTrue(replacementWasInstalled)
        XCTAssertEqual(try Data(contentsOf: marker), Data("replacement".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: replacement.path))
    }

    func testReleaseVerificationMarkerPreservesReplacementInstalledAfterQuarantine() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let marker = base.appendingPathComponent("toolchain-ready.json")
        let replacement = base.appendingPathComponent("replacement.json")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: replacement)
        var calls = ReleaseVerificationMarkerSystemCalls.system()
        let liveSynchronize = calls.synchronize
        let liveRenameExclusively = calls.renameExclusively
        var synchronizationAttempts = 0
        var replacementWasInstalled = false
        calls.synchronize = { descriptor in
            synchronizationAttempts += 1
            if synchronizationAttempts == 2 {
                errno = EIO
                return -1
            }
            return liveSynchronize(descriptor)
        }
        calls.renameExclusively = { directory, source, destination in
            let result = liveRenameExclusively(directory, source, destination)
            guard result == 0, !replacementWasInstalled else { return result }
            let renameResult = replacement.lastPathComponent.withCString { replacementName in
                source.withCString { sourceName in
                    renameat(directory, replacementName, directory, sourceName)
                }
            }
            guard renameResult == 0 else { return renameResult }
            replacementWasInstalled = true
            return result
        }

        XCTAssertThrowsError(try AppModel.writeReleaseVerificationMarker(
            Data("evidence".utf8),
            to: marker,
            systemCalls: calls
        )) { error in
            XCTAssertEqual(
                error as? ReleaseVerificationMarkerError,
                .operationFailed(operation: "sync the marker directory", errno: EIO)
            )
        }

        XCTAssertTrue(replacementWasInstalled)
        XCTAssertEqual(try Data(contentsOf: marker), Data("replacement".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path), [marker.lastPathComponent])
    }

    func testReleaseVerificationMarkerReportsUncertainCleanupWhenRemovalFails() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let marker = base.appendingPathComponent("toolchain-ready.json")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var calls = ReleaseVerificationMarkerSystemCalls.system()
        let liveSynchronize = calls.synchronize
        var synchronizationAttempts = 0
        calls.synchronize = { descriptor in
            synchronizationAttempts += 1
            if synchronizationAttempts == 2 {
                errno = EIO
                return -1
            }
            return liveSynchronize(descriptor)
        }
        calls.removeDestination = { _, _ in
            errno = EACCES
            return -1
        }

        XCTAssertThrowsError(try AppModel.writeReleaseVerificationMarker(
            Data("evidence".utf8),
            to: marker,
            systemCalls: calls
        )) { error in
            XCTAssertEqual(
                error as? ReleaseVerificationMarkerError,
                .rollbackFailed(operation: "remove the quarantined marker", errno: EACCES)
            )
            XCTAssertTrue(error.localizedDescription.contains("marker state is uncertain"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let remaining = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(try Data(contentsOf: remaining[0]), Data("evidence".utf8))
    }

    func testReleaseVerificationMarkerReportsUncertainCleanupWhenInspectionFails() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let marker = base.appendingPathComponent("toolchain-ready.json")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var calls = ReleaseVerificationMarkerSystemCalls.system()
        let liveSynchronize = calls.synchronize
        var synchronizationAttempts = 0
        calls.synchronize = { descriptor in
            synchronizationAttempts += 1
            if synchronizationAttempts == 2 {
                errno = EIO
                return -1
            }
            return liveSynchronize(descriptor)
        }
        calls.destinationStatus = { _, _, _ in
            errno = EACCES
            return -1
        }

        XCTAssertThrowsError(try AppModel.writeReleaseVerificationMarker(
            Data("evidence".utf8),
            to: marker,
            systemCalls: calls
        )) { error in
            XCTAssertEqual(
                error as? ReleaseVerificationMarkerError,
                .rollbackFailed(operation: "inspect the quarantined marker", errno: EACCES)
            )
            XCTAssertTrue(error.localizedDescription.contains("marker state is uncertain"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let remaining = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(try Data(contentsOf: remaining[0]), Data("evidence".utf8))
    }

    func testReleaseVerificationMarkerReportsUncertainCleanupWhenRemovalSyncFails() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let marker = base.appendingPathComponent("toolchain-ready.json")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var calls = ReleaseVerificationMarkerSystemCalls.system()
        let liveSynchronize = calls.synchronize
        var synchronizationAttempts = 0
        calls.synchronize = { descriptor in
            synchronizationAttempts += 1
            switch synchronizationAttempts {
            case 2:
                errno = EIO
                return -1
            case 3:
                errno = ENOSPC
                return -1
            default:
                return liveSynchronize(descriptor)
            }
        }

        XCTAssertThrowsError(try AppModel.writeReleaseVerificationMarker(
            Data("evidence".utf8),
            to: marker,
            systemCalls: calls
        )) { error in
            XCTAssertEqual(
                error as? ReleaseVerificationMarkerError,
                .rollbackFailed(operation: "sync the marker removal", errno: ENOSPC)
            )
            XCTAssertTrue(error.localizedDescription.contains("marker state is uncertain"))
        }

        XCTAssertEqual(synchronizationAttempts, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testReleaseVerificationMarkerSyncsExternallyRemovedDestinationDuringRollback() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let marker = base.appendingPathComponent("toolchain-ready.json")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var calls = ReleaseVerificationMarkerSystemCalls.system()
        let liveSynchronize = calls.synchronize
        var synchronizationAttempts = 0
        calls.synchronize = { descriptor in
            synchronizationAttempts += 1
            if synchronizationAttempts == 2 {
                errno = EIO
                return -1
            }
            return liveSynchronize(descriptor)
        }
        calls.renameExclusively = { directory, source, _ in
            let removed = source.withCString { unlinkat(directory, $0, 0) }
            XCTAssertEqual(removed, 0)
            errno = ENOENT
            return -1
        }

        XCTAssertThrowsError(try AppModel.writeReleaseVerificationMarker(
            Data("evidence".utf8),
            to: marker,
            systemCalls: calls
        )) { error in
            XCTAssertEqual(
                error as? ReleaseVerificationMarkerError,
                .operationFailed(operation: "sync the marker directory", errno: EIO)
            )
        }
        XCTAssertEqual(synchronizationAttempts, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testReleaseVerificationMarkerSyncsExternallyRemovedQuarantineDuringRollback() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let marker = base.appendingPathComponent("toolchain-ready.json")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var calls = ReleaseVerificationMarkerSystemCalls.system()
        let liveSynchronize = calls.synchronize
        var synchronizationAttempts = 0
        calls.synchronize = { descriptor in
            synchronizationAttempts += 1
            if synchronizationAttempts == 2 {
                errno = EIO
                return -1
            }
            return liveSynchronize(descriptor)
        }
        calls.removeDestination = { directory, name in
            let removed = name.withCString { unlinkat(directory, $0, 0) }
            XCTAssertEqual(removed, 0)
            errno = ENOENT
            return -1
        }

        XCTAssertThrowsError(try AppModel.writeReleaseVerificationMarker(
            Data("evidence".utf8),
            to: marker,
            systemCalls: calls
        )) { error in
            XCTAssertEqual(
                error as? ReleaseVerificationMarkerError,
                .operationFailed(operation: "sync the marker directory", errno: EIO)
            )
        }
        XCTAssertEqual(synchronizationAttempts, 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: base.path), [])
    }

    func testDefaultToolchainManagerFactoryReceivesTheDevelopmentOverrideRoot() {
        let localRoot = URL(fileURLWithPath: "/private/tmp/easysplat-toolchain", isDirectory: true)
        var receivedLocalRoot: URL?

        _ = AppModel.makeDefaultToolchainManager(
            developmentOverrides: DevelopmentOverrides(localToolchainRoot: localRoot)
        ) { explicitLocalRoot in
            receivedLocalRoot = explicitLocalRoot
            return MockToolchainManager()
        }

        XCTAssertEqual(receivedLocalRoot, localRoot)
    }

    func testDefaultToolchainManagerFactoryReceivesNoLocalRootWithoutDevelopmentOverride() {
        var receivedLocalRoot: URL?

        _ = AppModel.makeDefaultToolchainManager(developmentOverrides: .none) { explicitLocalRoot in
            receivedLocalRoot = explicitLocalRoot
            return MockToolchainManager()
        }

        XCTAssertNil(receivedLocalRoot)
    }

    private func releasePhotoInputManifest(
        inputRoot: URL,
        photoFolderName: String
    ) throws -> URL {
        let manifest = inputRoot.appendingPathComponent("release-input-manifest.json")
        let data = try JSONSerialization.data(
            withJSONObject: [
                "photoFolder": photoFolderName,
                "schemaVersion": 1,
                "videos": [],
            ],
            options: [.sortedKeys]
        )
        try data.write(to: manifest)
        return manifest
    }

    func testErrorDetailsTextCombinesFields() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }
        model.statusDetail = "detail"
        model.errorDetails = "error"
        model.logLines = ["a", "b"]
        model.errorLogLines = ["[err] traceback line"]

        let text = model.errorDetailsText ?? ""
        XCTAssertTrue(text.contains("detail"))
        XCTAssertTrue(text.contains("error"))
        XCTAssertTrue(text.contains("Error Logs:"))
        XCTAssertTrue(text.contains("Logs:"))
    }

    func testToolchainProgressLoggingBucketsAndMilestones() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }

        model.test_applyToolchainProgress(fraction: 0.01, message: "Downloading tools (core) 1 MB/100 MB (1 MB/s)")
        model.test_applyToolchainProgress(fraction: 0.04, message: "Downloading tools (core) 4 MB/100 MB (1 MB/s)")
        model.test_applyToolchainProgress(fraction: 0.09, message: "Downloading tools (core) 9 MB/100 MB (1 MB/s)")
        model.test_applyToolchainProgress(fraction: 0.11, message: "Downloading tools (core) 11 MB/100 MB (1 MB/s)")
        model.test_applyToolchainProgress(fraction: -1.0, message: "Verified download integrity (core)")
        model.test_applyToolchainProgress(fraction: -1.0, message: "Verified download integrity (core)")
        model.test_applyToolchainProgress(fraction: -1.0, message: "Unpacking tools (models)")
        model.test_applyToolchainProgress(fraction: -1.0, message: "Unpacking tools (models): found 2/2 expected files")
        model.test_applyToolchainProgress(fraction: 0.23, message: "Downloading tools (models) 23 MB/100 MB (1 MB/s)")
        model.test_applyToolchainProgress(fraction: 0.27, message: "Downloading tools (models) 27 MB/100 MB (1 MB/s)")

        XCTAssertEqual(model.statusDetail, "Downloading tools (models) 27 MB/100 MB (1 MB/s)")

        let coreDownloadLines = model.logLines.filter { $0.contains("[Tools] Downloading tools (core)") }
        XCTAssertEqual(coreDownloadLines.count, 2, "Expected one line per 10% bucket for core downloads.")

        XCTAssertTrue(model.logLines.contains("[Tools] Verified download integrity (core)"))
        XCTAssertTrue(model.logLines.contains("[Tools] Unpacking tools (models)"))
        XCTAssertTrue(model.logLines.contains("[Tools] Unpacking tools (models): found 2/2 expected files"))

        let duplicateIntegrityLines = model.logLines.filter { $0 == "[Tools] Verified download integrity (core)" }
        XCTAssertEqual(duplicateIntegrityLines.count, 1, "Indeterminate milestones should not be duplicated.")
    }

    func testShareUsesOnlyValidatedCurrentProjectPlyAndWritesNoAppEvents() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            videoInputPreflight: passingVideoPreflight()
        ) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        model.addInputs(urls: [input])
        model.startFromPendingSelection()
        try await waitForViewState(model: model, state: .viewer)

        let projectURL = try XCTUnwrap(model.currentProjectURL)
        let outputURL = try XCTUnwrap(model.outputPlyURL)
        await model.prepareCurrentSplatForSharing()
        let preparedItem = try XCTUnwrap(model.test_preparedShareItem())
        XCTAssertEqual(preparedItem.outputURL.standardizedFileURL, outputURL.standardizedFileURL)
        XCTAssertFalse(ProjectSummary.hasSameLocation(preparedItem.shareURL, outputURL))
        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: preparedItem.shareURL), .valid)
        XCTAssertEqual(try posixPermissions(at: preparedItem.shareDirectoryURL) & 0o777, 0o700)
        XCTAssertEqual(try posixPermissions(at: preparedItem.shareURL) & 0o777, 0o600)
        let outputBytes = try XCTUnwrap(outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertEqual(preparedItem.byteCount, Int64(outputBytes))
        XCTAssertTrue(model.isShareReady)

        let appEventsURL = projectURL.appendingPathComponent("Logs/app_events.jsonl")
        XCTAssertFalse(FileManager.default.fileExists(atPath: appEventsURL.path))

        let shareDirectoryURL = preparedItem.shareDirectoryURL
        model.cancelSharing()
        XCTAssertFalse(FileManager.default.fileExists(atPath: shareDirectoryURL.path))
    }

    func testSharePreparationReportsMissingOutputFile() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            videoInputPreflight: passingVideoPreflight()
        ) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        model.addInputs(urls: [input])
        model.startFromPendingSelection()
        try await waitForViewState(model: model, state: .viewer)

        guard let projectURL = model.currentProjectURL, let output = model.outputPlyURL else {
            XCTFail("Missing project state")
            return
        }
        try FileManager.default.removeItem(at: output)

        await model.prepareCurrentSplatForSharing()

        XCTAssertTrue(model.shareStatusIsError)
        XCTAssertEqual(
            model.shareStatusMessage,
            "Could not find splat.ply. Rebuild or reopen the project."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: projectURL.appendingPathComponent("Logs/app_events.jsonl").path
            )
        )
    }

    func testSharePreparationReportsInvalidOutputDirectoryPath() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            videoInputPreflight: passingVideoPreflight()
        ) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        model.addInputs(urls: [input])
        model.startFromPendingSelection()
        try await waitForViewState(model: model, state: .viewer)

        guard let output = model.outputPlyURL else {
            XCTFail("Missing project state")
            return
        }
        try FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        await model.prepareCurrentSplatForSharing()

        XCTAssertTrue(model.shareStatusIsError)
    }

    func testSharePreparationRejectsFallbackOutputFromDifferentProject() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let firstURL = try makeProject(at: tempBase, name: "First", lastError: nil, withOutput: true)
        let secondURL = try makeProject(at: tempBase, name: "Second", lastError: nil, withOutput: false)
        let firstOutput = ProjectPaths(root: firstURL).outputURL.appendingPathComponent("splat.ply")
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: secondURL, config: config)
        }
        model.currentProjectURL = secondURL
        model.outputPlyURL = firstOutput

        await model.prepareCurrentSplatForSharing()

        XCTAssertTrue(model.shareStatusIsError)
        XCTAssertNil(model.test_preparedShareItem())
        XCTAssertFalse(model.isShareReady)
    }

    func testPreparedSharePresentationIsIgnoredWhileSessionAlreadyActive() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            videoInputPreflight: passingVideoPreflight()
        ) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        model.addInputs(urls: [input])
        model.startFromPendingSelection()
        try await waitForViewState(model: model, state: .viewer)

        model.test_activateShareSession()

        await model.presentPreparedShare(from: NSButton())

        XCTAssertEqual(model.shareStatusMessage, "Share is already open.")
        XCTAssertFalse(model.shareStatusIsError)
        XCTAssertTrue(model.isShareSheetActive)
    }

    func testResetClosesTheActiveShareSessionExactlyOnce() throws {
        let model = AppModel(toolchainManager: MockToolchainManager()) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }
        model.test_activateShareSession()
        let session = try XCTUnwrap(model.activeShareSession)

        model.reset()

        XCTAssertNil(model.activeShareSession)
        XCTAssertFalse(model.isShareSheetActive)
        XCTAssertFalse(session.close(), "reset() must close rather than merely release the picker session")
    }

    func testErrorStageLogsBypassThrottle() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            videoInputPreflight: passingVideoPreflight()
        ) { _, _ in
            TracebackSpamPipelineRunner()
        }

        model.addInputs(urls: [input])
        model.startFromPendingSelection()

        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline, model.lastError == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertNotNil(model.lastError)
        try await Task.sleep(nanoseconds: 150_000_000)

        let tracebackLines = model.logLines.filter {
            $0.contains("Traceback (most recent call last):")
                || $0.contains("File \"run.py\"")
                || $0.contains("RuntimeError: MPS backend out of memory")
        }
        XCTAssertGreaterThanOrEqual(tracebackLines.count, 3)
        XCTAssertGreaterThanOrEqual(model.errorLogLines.count, 3)
        let details = model.errorDetailsText ?? ""
        XCTAssertTrue(details.contains("Traceback (most recent call last):"))
    }

    private func passingVideoPreflight() -> VideoInputPreflight {
        VideoInputPreflight(
            limits: .init(
                maximumVideoCount: 64,
                maximumTotalBytes: 1_073_741_824,
                minimumFreeSpaceReserveBytes: 0,
                maximumConcurrentDecoders: 2
            ),
            availableCapacity: { _ in Int64.max },
            analyze: { _, _ in .fixture }
        )
    }

    private func writeControlledVideoReceipt(
        paths: ProjectPaths,
        bytes: Data = Data("test-video".utf8)
    ) throws -> (url: URL, receipt: VideoInputReceipt) {
        try paths.ensureDirectories()
        let relativePath = "Originals/video-0000.mov"
        let url = paths.originalsURL.appendingPathComponent("video-0000.mov")
        try bytes.write(to: url, options: [.atomic])
        let sourceSHA256 = try GeometryArtifactStore.sha256(of: url)
        let policy = VideoFrameAnalysisPolicy(targetFrameCeiling: 250, targetFPS: 3)
        let analysisURL = paths.videoFrameAnalysisURL(index: 0)
        let analysisEvidence = try VideoFrameAnalysisArtifactStore.save(
            VideoFrameAnalysisArtifact(
                sourceIndex: 0,
                sourceProjectRelativePath: relativePath,
                sourceByteCount: Int64(bytes.count),
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
            ),
            to: analysisURL,
            projectPaths: paths
        )
        return (
            url,
            VideoInputReceipt(
                projectRelativePath: relativePath,
                safeDisplayName: "Capture.mov",
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
                clipGroupID: "video_000",
                analysisPolicySHA256: policy.sha256,
                analysisArtifactPath: try paths.projectRelativePath(for: analysisURL),
                analysisArtifactByteCount: analysisEvidence.byteCount,
                analysisArtifactSHA256: analysisEvidence.sha256
            )
        )
    }

    private enum DeferredProjectMutationAction {
        case resume
        case retrain
        case retry
    }

    private func assertCancellingDeferredProjectMutationRetiresRun(
        _ action: DeferredProjectMutationAction
    ) async throws {
        let tempBase = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempBase) }
        let projectURL = tempBase.appendingPathComponent(
            "Deferred Current.easysplatproj",
            isDirectory: true
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        var metadata = ProjectMetadata(
            title: "Deferred Current",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced
            ),
            state: PipelineState(stage: .done, lastError: nil)
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: standardHardwareProfile,
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let publicationID = UUID()
        let sourceURL = paths.trainingURL.appendingPathComponent("current.ply")
        try writeMinimalPly(at: sourceURL)
        let result = try publishAppTestResult(
            sourceURL: sourceURL,
            paths: paths,
            metadata: metadata,
            publicationID: publicationID
        )
        let nextProjectURL = try makeProject(
            at: tempBase,
            name: "Deferred Target",
            lastError: nil,
            withOutput: false,
            stage: .sfmMapping
        )
        let timingStarted = expectation(
            description: "viewer timing updater blocked before mutation"
        )
        let timingFinished = expectation(
            description: "viewer timing updater retired"
        )
        let receiptUpdater = BlockingViewerTimingReceiptUpdateProbe(
            phase: .beforeUpdate,
            started: timingStarted,
            finished: timingFinished
        )
        defer { receiptUpdater.release() }
        let runnerFactoryCalls = LockedCallCounter()
        let model = AppModel(
            toolchainManager: MockToolchainManager(),
            projectBaseURL: tempBase,
            hardwareProfile: standardHardwareProfile,
            pipelineRunnerFactory: { url, config in
                runnerFactoryCalls.record()
                return MockPipelineRunner(projectURL: url, config: config)
            },
            resultViewerTimingReceiptUpdater: receiptUpdater.update
        )
        model.currentProjectURL = projectURL
        model.outputPlyURL = result.outputURL
        model.viewState = .viewer
        let samples = LockedRunTimingSamples([
            .init(wallClock: Date(), monotonicSeconds: 20),
            .init(wallClock: Date(), monotonicSeconds: 25),
        ])
        model.prepareResultViewerTiming(
            projectID: metadata.id,
            projectURL: projectURL,
            outputURL: result.outputURL,
            expectedPublicationID: publicationID,
            boundary: .capture(sample: samples.next)
        )
        model.resultViewerDidBecomeReady(
            projectURL: projectURL,
            outputURL: result.outputURL
        )
        await fulfillment(of: [timingStarted], timeout: 2)
        let metadataBefore = try Data(contentsOf: paths.metadataURL)
        let receiptBefore = try Data(contentsOf: paths.outputSplatReceiptURL)

        switch action {
        case .resume:
            XCTAssertTrue(model.resumeProject(at: nextProjectURL))
        case .retrain:
            XCTAssertTrue(
                model.retrainProject(at: projectURL, profile: .highDetail)
            )
        case .retry:
            model.validationRecovery = .useFast
            model.failureRetryAllowed = true
            model.retryAfterFailure()
        }
        let deferredTask = try XCTUnwrap(model.currentTask)
        XCTAssertTrue(model.isRunActive)

        model.cancelCurrentProject(deleteProject: false)
        XCTAssertTrue(model.isRunActive)
        receiptUpdater.release()
        await fulfillment(of: [timingFinished], timeout: 2)
        await deferredTask.value

        XCTAssertFalse(model.isRunActive)
        XCTAssertNil(model.currentTask)
        XCTAssertNil(model.currentTaskToken)
        XCTAssertNil(model.stopAction)
        XCTAssertEqual(model.viewState, .home)
        XCTAssertNil(model.currentProjectURL)
        XCTAssertEqual(runnerFactoryCalls.count, 0)
        XCTAssertEqual(try Data(contentsOf: paths.metadataURL), metadataBefore)
        XCTAssertEqual(
            try Data(contentsOf: paths.outputSplatReceiptURL),
            receiptBefore
        )
    }

    private func waitForViewState(model: AppModel, state: AppModel.ViewState, timeout: TimeInterval = 2.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if model.viewState == state {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for viewState to become \(state)")
    }

    private func waitForRunToFinish(
        model: AppModel,
        timeout: TimeInterval = 2
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if !model.isRunActive, model.currentTask == nil { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for the project task to finish")
    }

    private func waitForPublishedViewerTiming(
        paths: ProjectPaths,
        expectedSeconds: TimeInterval,
        timeout: TimeInterval = 2
    ) async throws -> PublishedSplatReceipt {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let receipt = try? PublishedSplatReceiptStore.load(
                projectPaths: paths
            ), receipt.presentation.createToViewerReadySeconds
                == expectedSeconds {
                return receipt
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for the viewer timing receipt update")
        return try PublishedSplatReceiptStore.load(projectPaths: paths)
    }

    private func waitForPersistedViewerTiming(
        paths: ProjectPaths,
        expectedSeconds: TimeInterval,
        timeout: TimeInterval = 2
    ) async throws -> ProjectMetadata {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let metadata = try? ProjectMetadataStore.load(
                from: paths.metadataURL
            ), metadata.createToViewerReadySeconds == expectedSeconds {
                return metadata
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for the project viewer timing update")
        return try ProjectMetadataStore.load(from: paths.metadataURL)
    }

    private func waitForViewerTimingReceiptAttempt(
        model: AppModel,
        timeout: TimeInterval = 2
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if model.pendingResultViewerTiming == nil
                || model.pendingResultViewerTiming?.isReceiptUpdateInFlight
                    == false {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for the viewer timing receipt attempt")
    }

    private func waitForViewerTimingTaskToFinish(
        model: AppModel,
        timeout: TimeInterval = 2
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if model.resultViewerTimingTask == nil { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for the viewer timing task to finish")
    }

    private func waitForDeferredProjectMutationToFinish(
        model: AppModel,
        timeout: TimeInterval = 2
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while ContinuousClock.now < deadline {
            if model.deferredProjectMutationTask == nil { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for the deferred project mutation")
    }

    private func waitForCurrentProjectURL(model: AppModel, url: URL, timeout: TimeInterval = 2.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if model.currentProjectURL == url {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for currentProjectURL to become \(url)")
    }

    private func waitForLastError(model: AppModel, timeout: TimeInterval = 2.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if model.lastError != nil {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for lastError")
    }

    private func waitForPipelineState(
        model: AppModel,
        stage: PipelineStage,
        timeout: TimeInterval = 2.0
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if model.stage == stage {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for stage \(stage)")
    }

    private func makeProject(
        at base: URL,
        name: String,
        lastError: String?,
        withOutput: Bool,
        checkpoint: PipelineCheckpoint? = nil,
        stage: PipelineStage = .done,
        lastRunStartedAt: Date? = nil
    ) throws -> URL {
        let url = base.appendingPathComponent("\(name).easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: url)
        try paths.ensureDirectories()
        let outputURL = paths.outputURL.appendingPathComponent("splat.ply")
        if withOutput {
            try FileManager.default.createDirectory(at: paths.outputURL, withIntermediateDirectories: true)
            try writeMinimalPly(at: outputURL)
        }
        var metadata = ProjectMetadata(
            title: name,
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            state: PipelineState(stage: stage, lastError: lastError),
            checkpoint: checkpoint,
            lastRunStartedAt: lastRunStartedAt
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        if withOutput {
            try persistCompletedAppTestArtifacts(
                metadata: metadata,
                paths: paths,
                trainingArtifact: makeCompletedTrainingArtifact(
                    for: outputURL,
                    metadata: metadata
                )
            )
        }
        return url
    }

    private struct SkippedProjectSnapshot {
        let metadataURL: URL
        let metadataBytes: Data
        let metadataDate: Date
        let sentinelURL: URL
        let sentinelBytes: Data
        let sentinelDate: Date
    }

    private func makeSkippedProject(
        at base: URL,
        name: String,
        metadata: String
    ) throws -> SkippedProjectSnapshot {
        let projectURL = base.appendingPathComponent("\(name).easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let metadataURL = projectURL.appendingPathComponent("project.json")
        let sentinelURL = projectURL.appendingPathComponent("do-not-touch.bin")
        try Data(metadata.utf8).write(to: metadataURL)
        try Data("preserve \(name)".utf8).write(to: sentinelURL)
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: metadataURL.path)
        try FileManager.default.setAttributes([.modificationDate: fixedDate], ofItemAtPath: sentinelURL.path)
        return SkippedProjectSnapshot(
            metadataURL: metadataURL,
            metadataBytes: try Data(contentsOf: metadataURL),
            metadataDate: try modificationDate(of: metadataURL),
            sentinelURL: sentinelURL,
            sentinelBytes: try Data(contentsOf: sentinelURL),
            sentinelDate: try modificationDate(of: sentinelURL)
        )
    }

    private func assertSkippedProjectsUnchanged(
        _ snapshots: [SkippedProjectSnapshot],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for snapshot in snapshots {
            XCTAssertEqual(
                try Data(contentsOf: snapshot.metadataURL),
                snapshot.metadataBytes,
                file: file,
                line: line
            )
            XCTAssertEqual(
                try modificationDate(of: snapshot.metadataURL),
                snapshot.metadataDate,
                file: file,
                line: line
            )
            XCTAssertEqual(
                try Data(contentsOf: snapshot.sentinelURL),
                snapshot.sentinelBytes,
                file: file,
                line: line
            )
            XCTAssertEqual(
                try modificationDate(of: snapshot.sentinelURL),
                snapshot.sentinelDate,
                file: file,
                line: line
            )
        }
    }

    private func modificationDate(of url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.modificationDate] as? Date)
    }
}

private func writeTestGrayscaleImage(at url: URL, value: UInt8) throws -> Bool {
    let width = 2
    let height = 2
    var pixels = [UInt8](repeating: value, count: width * height)
    let data = Data(bytes: &pixels, count: pixels.count)
    guard let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(
              width: width,
              height: height,
              bitsPerComponent: 8,
              bitsPerPixel: 8,
              bytesPerRow: width,
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
        return false
    }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

private actor AppTestEnvironmentLock {
    static let shared = AppTestEnvironmentLock()
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func unlock() {
        if waiters.isEmpty {
            locked = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }
}

@MainActor
@discardableResult
private func withAppEnvironmentAsync<T>(
    _ changes: [String: String?],
    _ body: @MainActor () async throws -> T
) async rethrows -> T {
    await AppTestEnvironmentLock.shared.lock()
    let previous = captureAppEnvironment(changes)
    applyAppEnvironment(changes)
    do {
        let result = try await body()
        restoreAppEnvironment(previous)
        await AppTestEnvironmentLock.shared.unlock()
        return result
    } catch {
        restoreAppEnvironment(previous)
        await AppTestEnvironmentLock.shared.unlock()
        throw error
    }
}

private func appResourceURL(named name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("EasySplatApp/Resources/\(name)")
}

private func makeToolchainBootstrapFixture() throws -> (
    resourceRoot: URL,
    bootstrapRoot: URL,
    manifestURL: URL,
    coreArchiveURL: URL
) {
    let resourceRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let bootstrapRoot = resourceRoot
        .appendingPathComponent("ToolchainBootstrap", isDirectory: true)
    try FileManager.default.createDirectory(at: bootstrapRoot, withIntermediateDirectories: true)
    let manifestURL = bootstrapRoot.appendingPathComponent("manifest.json", isDirectory: false)
    let coreArchiveURL = bootstrapRoot.appendingPathComponent("macos-arm64-core.zip", isDirectory: false)
    try Data("manifest".utf8).write(to: manifestURL)
    try Data("core".utf8).write(to: coreArchiveURL)
    return (resourceRoot, bootstrapRoot, manifestURL, coreArchiveURL)
}

private func captureAppEnvironment(_ changes: [String: String?]) -> [String: String?] {
    var previous: [String: String?] = [:]
    for key in changes.keys {
        previous[key] = RuntimeEnvironment.value(forKey: key)
    }
    return previous
}

private func applyAppEnvironment(_ changes: [String: String?]) {
    for (key, value) in changes {
        RuntimeEnvironment.setValue(value, forKey: key)
    }
}

private func restoreAppEnvironment(_ previous: [String: String?]) {
    for (key, value) in previous {
        RuntimeEnvironment.setValue(value, forKey: key)
    }
}

private func makeMockToolchainPaths() -> ToolchainPaths {
    let da3Root = URL(fileURLWithPath: "/mock/da3")
    return ToolchainPaths(
        root: URL(fileURLWithPath: "/tmp/toolchain"),
        dataRoot: URL(fileURLWithPath: "/tmp/toolchain"),
        toolchainIdentity: "local-toolchain",
        colmap: URL(fileURLWithPath: "/mock/colmap"),
        msplat: URL(fileURLWithPath: "/mock/easysplat-train"),
        metallib: URL(fileURLWithPath: "/mock/default.metallib"),
        da3: Da3Toolchain(
            root: da3Root,
            sfmTool: da3Root.appendingPathComponent("bin/easysplat_da3_sfm"),
            python: da3Root.appendingPathComponent("python/bin/python3"),
            models: da3Root.appendingPathComponent("models"),
            modelBundle: da3Root.appendingPathComponent("models/da3-base.safetensors"),
            smallModelBundle: da3Root.appendingPathComponent("models/da3-small.safetensors")
        )
    )
}

private final class LockedRunTimingSamples: @unchecked Sendable {
    private let lock = NSLock()
    private let samples: [RunTimingBoundary.Sample]
    private var nextIndex = 0

    init(_ samples: [RunTimingBoundary.Sample]) {
        self.samples = samples
    }

    var readCount: Int {
        lock.withLock { nextIndex }
    }

    func next() -> RunTimingBoundary.Sample {
        lock.withLock {
            precondition(nextIndex < samples.count, "Run timing sample was read more than expected")
            defer { nextIndex += 1 }
            return samples[nextIndex]
        }
    }
}

final class MockToolchainManager: ToolchainManaging {
    func resolveToolchain(
        request: ToolchainCapabilityRequest,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        makeMockToolchainPaths()
    }
}

final class CapabilityRecordingToolchainManager: @unchecked Sendable, ToolchainManaging {
    private let queue = DispatchQueue(label: "CapabilityRecordingToolchainManager")
    private var requests: [ToolchainCapabilityRequest] = []

    var lastRequest: ToolchainCapabilityRequest? {
        queue.sync { requests.last }
    }

    var requestCount: Int {
        queue.sync { requests.count }
    }

    func resolveToolchain(
        request: ToolchainCapabilityRequest,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        queue.sync { requests.append(request) }
        return makeMockToolchainPaths()
    }
}

struct FailingToolchainManager: ToolchainManaging {
    var message: String

    func resolveToolchain(
        request: ToolchainCapabilityRequest,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        throw NSError(domain: "FailingToolchainManager", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

struct DamagedToolchainManager: ToolchainManaging {
    var message: String

    func resolveToolchain(
        request: ToolchainCapabilityRequest,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        throw ToolchainManager.ToolchainError.invalidToolchain(message)
    }
}

final class BlockingPipelineRunner: PipelineRunning {
    func run(resumeFrom lastCompletedStage: PipelineStage?, events: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        events(.stageStarted(stage: .trainSplat))
        while true {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

final class StopFailingPipelineRunner: PipelineRunning {
    private let started: XCTestExpectation
    private let stage: PipelineStage

    init(started: XCTestExpectation, stage: PipelineStage) {
        self.started = started
        self.stage = stage
    }

    func run(
        resumeFrom lastCompletedStage: PipelineStage?,
        events: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        events(.stageStarted(stage: stage))
        started.fulfill()
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } catch {
            throw NSError(
                domain: "CheckpointSaveFailingPipelineRunner",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "checkpoint persistence failed"]
            )
        }
    }
}

final class ImmediateCancellationPipelineRunner: PipelineRunning {
    func run(resumeFrom lastCompletedStage: PipelineStage?, events: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        throw CancellationError()
    }
}

final class MockPipelineRunner: PipelineRunning {
    private let projectURL: URL
    private let config: PipelineRunner.PipelineConfig

    init(projectURL: URL, config: PipelineRunner.PipelineConfig) {
        self.projectURL = projectURL
        self.config = config
    }

    func run(resumeFrom lastCompletedStage: PipelineStage?, events: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        events(.stageStarted(stage: .importInput))
        events(.stageFinished(stage: .importInput))

        let paths = ProjectPaths(root: projectURL)
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let outputURL = paths.outputURL.appendingPathComponent("splat.ply")
        try FileManager.default.createDirectory(at: paths.outputURL, withIntermediateDirectories: true)
        try writeMinimalPly(at: outputURL)
        let trainingArtifact = try makeCompletedTrainingArtifact(
            for: outputURL,
            metadata: metadata
        )
        metadata.state = PipelineState(stage: .done, lastError: nil)
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        try persistCompletedAppTestArtifacts(
            metadata: metadata,
            paths: paths,
            trainingArtifact: trainingArtifact
        )
    }
}

final class PublishedResultMockPipelineRunner: PipelineRunning {
    private let projectURL: URL
    private let config: PipelineRunner.PipelineConfig
    private let publicationID: UUID

    init(
        projectURL: URL,
        config: PipelineRunner.PipelineConfig,
        publicationID: UUID
    ) {
        self.projectURL = projectURL
        self.config = config
        self.publicationID = publicationID
    }

    func run(
        resumeFrom lastCompletedStage: PipelineStage?,
        events: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        try await MockPipelineRunner(
            projectURL: projectURL,
            config: config
        ).run(resumeFrom: lastCompletedStage, events: events)

        let paths = ProjectPaths(root: projectURL)
        let sourceDirectory = paths.trainingURL.appendingPathComponent(
            "app-test-publication",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let sourceURL = sourceDirectory.appendingPathComponent("splat.ply")
        try FileManager.default.copyItem(
            at: paths.outputSplatURL,
            to: sourceURL
        )
        try FileManager.default.removeItem(at: paths.outputSplatURL)
        let metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        _ = try publishAppTestResult(
            sourceURL: sourceURL,
            paths: paths,
            metadata: metadata,
            publicationID: publicationID
        )
    }
}

final class FreshAttestationRecordingPipelineRunner: PipelineRunning {
    private let projectURL: URL
    private let config: PipelineRunner.PipelineConfig
    private(set) var freshAttestationRunCount = 0
    private(set) var legacyRunCount = 0

    init(projectURL: URL, config: PipelineRunner.PipelineConfig) {
        self.projectURL = projectURL
        self.config = config
    }

    func run(
        resumeFrom lastCompletedStage: PipelineStage?,
        events: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        legacyRunCount += 1
        try await MockPipelineRunner(projectURL: projectURL, config: config).run(
            resumeFrom: lastCompletedStage,
            events: events
        )
    }

    func run(
        resumeFrom lastCompletedStage: PipelineStage?,
        freshPublicationAttestation: FreshProjectPublicationAttestation,
        events: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        freshAttestationRunCount += 1
        try await MockPipelineRunner(projectURL: projectURL, config: config).run(
            resumeFrom: lastCompletedStage,
            events: events
        )
    }
}

final class FreshAttestationCancellingPipelineRunner: PipelineRunning {
    private(set) var attestation: FreshProjectPublicationAttestation?

    func run(
        resumeFrom lastCompletedStage: PipelineStage?,
        events: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        throw CancellationError()
    }

    func run(
        resumeFrom lastCompletedStage: PipelineStage?,
        freshPublicationAttestation: FreshProjectPublicationAttestation,
        events: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        attestation = freshPublicationAttestation
        throw CancellationError()
    }
}

final class ExecutableMutatingPipelineRunner: PipelineRunning {
    private let projectURL: URL
    private let config: PipelineRunner.PipelineConfig
    private let executableURL: URL

    init(
        projectURL: URL,
        config: PipelineRunner.PipelineConfig,
        executableURL: URL
    ) {
        self.projectURL = projectURL
        self.config = config
        self.executableURL = executableURL
    }

    func run(
        resumeFrom lastCompletedStage: PipelineStage?,
        events: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        try await MockPipelineRunner(projectURL: projectURL, config: config).run(
            resumeFrom: lastCompletedStage,
            events: events
        )
        try FileManager.default.removeItem(at: executableURL)
        try Data("replacement executable".utf8).write(to: executableURL)
    }
}

final class ResumeRecordingPipelineRunner: PipelineRunning {
    private let projectURL: URL
    private(set) var resumeFrom: PipelineStage?

    init(projectURL: URL) {
        self.projectURL = projectURL
    }

    func run(
        resumeFrom lastCompletedStage: PipelineStage?,
        events: @escaping @Sendable (PipelineEvent) -> Void
    ) async throws {
        resumeFrom = lastCompletedStage
        let paths = ProjectPaths(root: projectURL)
        let outputURL = paths.outputURL.appendingPathComponent("splat.ply")
        try FileManager.default.createDirectory(at: paths.outputURL, withIntermediateDirectories: true)
        try writeMinimalPly(at: outputURL)
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let trainingArtifact = try makeCompletedTrainingArtifact(
            for: outputURL,
            metadata: metadata
        )
        metadata.state = PipelineState(stage: .done, lastError: nil)
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        try persistCompletedAppTestArtifacts(
            metadata: metadata,
            paths: paths,
            trainingArtifact: trainingArtifact
        )
    }
}

final class MissingOutputPipelineRunner: PipelineRunning {
    private let projectURL: URL

    init(projectURL: URL) {
        self.projectURL = projectURL
    }

    func run(resumeFrom lastCompletedStage: PipelineStage?, events: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        let paths = ProjectPaths(root: projectURL)
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        metadata.state = PipelineState(stage: .done, lastError: nil)
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
    }
}

final class DirectoryOutputRepairingPipelineRunner: PipelineRunning {
    private let projectURL: URL
    private(set) var didRun = false

    init(projectURL: URL) {
        self.projectURL = projectURL
    }

    func run(resumeFrom lastCompletedStage: PipelineStage?, events: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        didRun = true
        let paths = ProjectPaths(root: projectURL)
        let outputURL = paths.outputURL.appendingPathComponent("splat.ply")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.createDirectory(at: paths.outputURL, withIntermediateDirectories: true)
        try writeMinimalPly(at: outputURL)

        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let trainingArtifact = try makeCompletedTrainingArtifact(
            for: outputURL,
            metadata: metadata
        )
        metadata.state = PipelineState(stage: .done, lastError: nil)
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        try persistCompletedAppTestArtifacts(
            metadata: metadata,
            paths: paths,
            trainingArtifact: trainingArtifact
        )
    }
}

final class TracebackSpamPipelineRunner: PipelineRunning {
    func run(resumeFrom lastCompletedStage: PipelineStage?, events: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        events(.stageStarted(stage: .sfmFeatures))
        events(.stageLog(stage: .sfmFeatures, line: "Traceback (most recent call last):", isError: true))
        events(.stageLog(stage: .sfmFeatures, line: "  File \"run.py\", line 287, in run_pipeline", isError: true))
        events(.stageLog(stage: .sfmFeatures, line: "RuntimeError: MPS backend out of memory", isError: true))
        events(.pipelineFailed(stage: .sfmFeatures, userMessage: "Pipeline failed", debugMessage: "traceback"))
        throw NSError(domain: "AppModelTests", code: 1)
    }
}

private func writeMinimalPly(at url: URL, vertexCount: Int = 1) throws {
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

@discardableResult
private func publishAppTestResult(
    sourceURL: URL,
    paths: ProjectPaths,
    metadata: ProjectMetadata,
    publicationID: UUID
) throws -> ValidatedPublishedResult {
    var publishingMetadata = metadata
    let plan = publishingMetadata.resolvedRunPlan ?? RunPlanResolver.resolve(
        requestedOptions: publishingMetadata.requestedRunOptions,
        input: publishingMetadata.input,
        hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
        developmentOverrides: .none
    )
    publishingMetadata.resolvedRunPlan = plan
    publishingMetadata.state = PipelineState(
        stage: .exportSplat,
        lastError: nil
    )
    publishingMetadata.checkpoint = nil
    publishingMetadata.lastRunStartedAt = Date(
        timeIntervalSince1970: 1_767_225_000
    )
    publishingMetadata.pendingPublicationID = publicationID
    var stageTimings = publishingMetadata.stageTimings ?? []
    if !stageTimings.contains(where: { $0.stage == .trainSplat }) {
        stageTimings.append(
            StageTimingRecord(
                stage: .trainSplat,
                startedAt: Date(timeIntervalSince1970: 1_767_225_500),
                durationSeconds: 1
            )
        )
    }
    publishingMetadata.stageTimings = stageTimings

    try FileManager.default.createDirectory(
        at: paths.msplatOutputURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    if FileManager.default.fileExists(atPath: paths.msplatOutputURL.path) {
        try FileManager.default.removeItem(at: paths.msplatOutputURL)
    }
    try FileManager.default.copyItem(at: sourceURL, to: paths.msplatOutputURL)
    var training = try makeCompletedTrainingArtifact(
        for: paths.msplatOutputURL,
        metadata: publishingMetadata
    )
    training.outputPath = "Training/msplat/splat.ply"
    try persistCompletedAppTestArtifacts(
        metadata: publishingMetadata,
        paths: paths,
        trainingArtifact: training
    )
    let geometry = try GeometryArtifactStore.loadManifest(
        from: paths.geometryManifestURL,
        projectPaths: paths
    )
    let result = try PublishedResultPublisher.publishCompletedTraining(
        metadata: publishingMetadata,
        resolvedRunPlan: plan,
        geometry: geometry,
        paths: paths,
        publicationID: publicationID,
        publishedAt: Date(timeIntervalSince1970: 1_767_225_600)
    )
    publishingMetadata.pendingPublicationID = nil
    publishingMetadata.lastRunStartedAt = nil
    publishingMetadata.state = PipelineState(stage: .done, lastError: nil)
    try ProjectMetadataStore.save(publishingMetadata, to: paths.metadataURL)
    return result
}

private func projectTrashQuarantineURLs(in parentURL: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: parentURL,
        includingPropertiesForKeys: nil,
        options: []
    ).filter {
        $0.lastPathComponent.hasPrefix(".easysplat-trash-")
    }
}

private final class ViewerTimingMetadataUpdateProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    var attemptCount: Int {
        lock.withLock { attempts }
    }

    func update(
        projectRootDescriptor: Int32,
        mutation: AppModel.ProjectMetadataMutation
    ) throws -> ProjectMetadata {
        let attempt = lock.withLock { () -> Int in
            attempts += 1
            return attempts
        }
        if attempt == 1 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
        }
        return try ProjectMetadataStore.update(
            atProjectRootDescriptor: projectRootDescriptor,
            mutation
        )
    }
}

private final class ViewerTimingMetadataSuccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    var attemptCount: Int {
        lock.withLock { attempts }
    }

    func update(
        projectRootDescriptor: Int32,
        mutation: AppModel.ProjectMetadataMutation
    ) throws -> ProjectMetadata {
        lock.withLock { attempts += 1 }
        return try ProjectMetadataStore.update(
            atProjectRootDescriptor: projectRootDescriptor,
            mutation
        )
    }
}

private final class LockedCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.withLock { value }
    }

    func record() {
        lock.withLock { value += 1 }
    }
}

private final class ViewerTimingRunLeaseProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let projectURL: URL
    private var acquisitions = 0
    private var receiptHeld = false
    private var metadataHeld = false

    init(projectURL: URL) {
        self.projectURL = projectURL
    }

    var acquireCount: Int {
        lock.withLock { acquisitions }
    }

    var receiptObservedHeldLease: Bool {
        lock.withLock { receiptHeld }
    }

    var metadataObservedHeldLease: Bool {
        lock.withLock { metadataHeld }
    }

    func acquire(projectURL: URL) throws -> ProjectRunLeaseOwner {
        lock.withLock { acquisitions += 1 }
        return try ProjectRunLeaseOwner.acquire(projectURL: projectURL)
    }

    func observeReceiptUpdate() {
        let held = observesHeldLease()
        lock.withLock { receiptHeld = held }
    }

    func observeMetadataUpdate() {
        let held = observesHeldLease()
        lock.withLock { metadataHeld = held }
    }

    private func observesHeldLease() -> Bool {
        do {
            let unexpected = try ProjectRunLease.acquire(projectURL: projectURL)
            unexpected.release()
            return false
        } catch ProjectRunLeaseError.alreadyRunning {
            return true
        } catch {
            return false
        }
    }
}

private final class ViewerTimingRootSwapProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let canonicalURL: URL
    private let replacementURL: URL
    private let parkedOriginalURL: URL
    private var attempts = 0

    init(
        canonicalURL: URL,
        replacementURL: URL,
        parkedOriginalURL: URL
    ) {
        self.canonicalURL = canonicalURL
        self.replacementURL = replacementURL
        self.parkedOriginalURL = parkedOriginalURL
    }

    var attemptCount: Int {
        lock.withLock { attempts }
    }

    func swapBeforeOpen() throws {
        let shouldSwap = lock.withLock { () -> Bool in
            attempts += 1
            return attempts == 1
        }
        guard shouldSwap else { return }
        try FileManager.default.moveItem(
            at: canonicalURL,
            to: parkedOriginalURL
        )
        try FileManager.default.moveItem(
            at: replacementURL,
            to: canonicalURL
        )
    }
}

private final class AlwaysFailingViewerTimingMetadataUpdateProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    var attemptCount: Int {
        lock.withLock { attempts }
    }

    func update(
        projectRootDescriptor _: Int32,
        mutation _: AppModel.ProjectMetadataMutation
    ) throws -> ProjectMetadata {
        lock.withLock { attempts += 1 }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
    }
}

private final class ViewerTimingMetadataLoadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let failuresBeforeSuccess: Int
    private var attempts = 0

    init(failuresBeforeSuccess: Int) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
    }

    var attemptCount: Int {
        lock.withLock { attempts }
    }

    func load(projectRootDescriptor: Int32) throws -> ProjectMetadata {
        let attempt = lock.withLock { () -> Int in
            attempts += 1
            return attempts
        }
        if attempt <= failuresBeforeSuccess {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO))
        }
        return try ProjectMetadataStore.load(
            fromProjectRootDescriptor: projectRootDescriptor
        )
    }
}

private final class ViewerTimingReceiptUpdateProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    var attemptCount: Int {
        lock.withLock { attempts }
    }

    func update(
        seconds: TimeInterval,
        expectedPublicationID: UUID,
        expectedGeneration: PublishedResultGeneration?,
        projectPaths: ProjectPaths,
        projectRootDescriptor: Int32?,
        operations: PublishedResultPairOperations,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws -> ValidatedPublishedResult {
        lock.withLock { attempts += 1 }
        return try PublishedResultPairStore.recordFirstViewerReadyTiming(
            seconds,
            expectedPublicationID: expectedPublicationID,
            expectedGeneration: expectedGeneration,
            projectPaths: projectPaths,
            projectRootDescriptor: projectRootDescriptor,
            operations: operations,
            shouldCancel: shouldCancel
        )
    }
}

private final class BlockingViewerTimingReceiptUpdateProbe: @unchecked Sendable {
    enum Phase {
        case beforeUpdate
        case afterUpdate
    }

    private let phase: Phase
    private let started: XCTestExpectation
    private let finished: XCTestExpectation
    private let gate = DispatchSemaphore(value: 0)

    init(
        phase: Phase,
        started: XCTestExpectation,
        finished: XCTestExpectation
    ) {
        self.phase = phase
        self.started = started
        self.finished = finished
    }

    func release() {
        gate.signal()
    }

    func update(
        seconds: TimeInterval,
        expectedPublicationID: UUID,
        expectedGeneration: PublishedResultGeneration?,
        projectPaths: ProjectPaths,
        projectRootDescriptor: Int32?,
        operations: PublishedResultPairOperations,
        shouldCancel: @escaping @Sendable () -> Bool
    ) throws -> ValidatedPublishedResult {
        defer { finished.fulfill() }
        if phase == .beforeUpdate {
            started.fulfill()
            gate.wait()
        }
        let result = try PublishedResultPairStore.recordFirstViewerReadyTiming(
            seconds,
            expectedPublicationID: expectedPublicationID,
            expectedGeneration: expectedGeneration,
            projectPaths: projectPaths,
            projectRootDescriptor: projectRootDescriptor,
            operations: operations,
            shouldCancel: shouldCancel
        )
        if phase == .afterUpdate {
            started.fulfill()
            gate.wait()
        }
        return result
    }
}

private func posixPermissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
}

private func visibleProjectBundles(in base: URL) throws -> [URL] {
    guard FileManager.default.fileExists(atPath: base.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(
        at: base,
        includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "easysplatproj" }
}

private func transactionLeaves(in base: URL) throws -> [String] {
    let container = base.appendingPathComponent(
        ProjectPublicationTransaction.containerName,
        isDirectory: true
    )
    guard FileManager.default.fileExists(atPath: container.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(atPath: container.path).filter {
        $0.hasPrefix("txn-") || $0.hasPrefix(".deleting-") || $0.hasPrefix(".cleanup-")
    }
}

private struct InjectedPublicationFailure: Error {}

private func makeCompletedTrainingArtifact(
    for outputURL: URL,
    metadata: ProjectMetadata,
    sceneBounds suppliedSceneBounds: SplatSceneBounds? = nil
) throws -> TrainingArtifact {
    // Snapshot load rejects artifacts whose trainer budget disagrees with the
    // persisted plan, so mirror the plan when one exists.
    let detailProfile = metadata.effectiveDetailProfile
    let budget: (iterationLimit: Int, plateauWindow: Int)
    if let plan = metadata.resolvedRunPlan {
        budget = (plan.trainerIterationLimit, plan.plateauWindow)
    } else {
        budget = (7_000, 800)
    }
    guard let header = ProjectArtifactValidator.readPlyHeader(at: outputURL),
          let fileSize = try outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let sceneBounds: SplatSceneBounds
    if let suppliedSceneBounds {
        sceneBounds = suppliedSceneBounds
    } else if let measuredSceneBounds = try SplatSceneBoundsCalculator.compute(
        at: outputURL,
        maximumSampleCount: RobustSplatBounds.maximumFallbackSampleCount
    ) {
        sceneBounds = measuredSceneBounds
    } else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return TrainingArtifact(
        trainerVersion: "test",
        runtimeVersion: "native-metal-cli-v2",
        trainerBuildDigest: String(repeating: "a", count: 64),
        inputDigest: String(repeating: "b", count: 64),
        geometryDigest: String(repeating: "c", count: 64),
        datasetDerivation: makeAppTestMsplatDatasetDerivation(),
        detailProfile: detailProfile,
        iterationLimit: budget.iterationLimit,
        plateauWindow: budget.plateauWindow,
        cameraOrderSeed: 42,
        completedIteration: 1,
        checkpointPath: nil,
        checkpointDigest: nil,
        outputPath: "Output/splat.ply",
        outputSHA256: try GeometryArtifactStore.sha256(of: outputURL),
        outputBytes: Int64(fileSize),
        gaussianCount: header.vertexCount,
        elapsedSeconds: 1,
        peakMemoryBytes: 1,
        memoryBudgetBytes: 1,
        resourceAdmission: makeAppTestTrainingResourceAdmission(),
        rasterFallbackCount: 0,
        rasterExactFallbackElapsedSeconds: 0,
        rasterExactBufferGrowthCount: 0,
        rasterExactBufferBytesAdded: 0,
        rasterReplayElapsedSeconds: 0,
        rasterPeakExactIntersectionCapacity: 0,
        droppedIntersectionCount: 0,
        sceneBounds: sceneBounds,
        completionStatus: .completed
    )
}

func makeAppTestMsplatDatasetDerivation() -> MsplatDatasetDerivationArtifact {
    MsplatDatasetDerivationArtifact(
        sourceGeometryManifestSHA256: String(repeating: "d", count: 64),
        sourceSelectedFramesDigest: String(repeating: "e", count: 64),
        preparationKind: .direct,
        maximumImageDimension: 1_024,
        toolchainVersion: "2.0.0",
        colmapProvenance: GeometryComponentProvenance(
            identifier: "colmap",
            version: "4.0.4",
            revision: String(repeating: "f", count: 40),
            payloadSHA256: String(repeating: "a", count: 64)
        ),
        registeredImageNames: ["frame_000000.jpg"],
        datasetInputDigest: String(repeating: "b", count: 64),
        datasetGeometryDigest: String(repeating: "c", count: 64)
    )
}
#endif
