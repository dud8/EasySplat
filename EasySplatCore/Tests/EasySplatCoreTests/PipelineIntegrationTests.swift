#if canImport(XCTest)
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
            hardwareProfile: hardwareProfile
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
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

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
    }

    func testMixedVideoSelectionUsesExactGlobalBudgetAndCleansCommittedRawFrames() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent(
            "MixedVideoSelection.easysplatproj",
            isDirectory: true
        )
        let firstVideo = temp.appendingPathComponent("first.mov")
        let secondVideo = temp.appendingPathComponent("second.mov")
        let firstTimes = [0.0, 0.02, 0.20, 0.22, 0.40, 0.42, 0.60, 0.62]
        let secondTimes = [0.0, 0.03, 0.15, 0.30]
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
        let photos = temp.appendingPathComponent("InvalidPhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        try Data("not an image".utf8).write(to: photos.appendingPathComponent("broken.jpg"))

        let metadata = ProjectMetadata(
            title: "Mixed selection",
            input: .mixed(
                videos: [firstVideo.path, secondVideo.path],
                photosFolder: photos.path
            ),
            requestedRunOptions: RequestedRunOptions(detailProfile: .fast)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
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
        let firstGroup = manifest.filter { $0.groupId == "video_000" }
        let secondGroup = manifest.filter { $0.groupId == "video_001" }
        XCTAssertEqual(firstGroup.count, firstTimes.count)
        XCTAssertEqual(secondGroup.count, secondTimes.count)
        XCTAssertEqual(manifest.count, firstTimes.count + secondTimes.count)
        XCTAssertEqual(firstGroup.first?.timestampSeconds ?? -1, firstTimes.first ?? -1, accuracy: 0.001)
        XCTAssertEqual(firstGroup.last?.timestampSeconds ?? -1, firstTimes.last ?? -1, accuracy: 0.001)
        XCTAssertEqual(secondGroup.first?.timestampSeconds ?? -1, secondTimes.first ?? -1, accuracy: 0.001)
        XCTAssertEqual(secondGroup.last?.timestampSeconds ?? -1, secondTimes.last ?? -1, accuracy: 0.001)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.framesRawURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.framesRawManifestURL.path))

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

    func testMultiVideoAnalysisRecoversBudgetAfterSparseClipSaturates() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent(
            "RedistributedVideoSelection.easysplatproj",
            isDirectory: true
        )
        let denseVideo = temp.appendingPathComponent("dense.mov")
        let sparseVideo = temp.appendingPathComponent("sparse.mov")
        let denseTimes = (0..<120).map { Double($0) / 12 }
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

        let metadata = ProjectMetadata(
            title: "Redistributed selection",
            input: .video(files: [denseVideo.path, sparseVideo.path]),
            requestedRunOptions: RequestedRunOptions(detailProfile: .fast)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
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
        XCTAssertEqual(manifest.filter { $0.groupId == "video_000" }.count, 118)
        XCTAssertEqual(manifest.filter { $0.groupId == "video_001" }.count, 2)
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
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

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
                    XCTAssertEqual(self.value(for: "--Mapper.ba_global_frames_ratio", in: args), "1.1")
                    XCTAssertEqual(self.value(for: "--Mapper.ba_global_points_ratio", in: args), "1.1")
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
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 100 / 100\nPoints: 100\nObservations: 300\nMean track length: 3.0\nMean reprojection error: 1.0\n", stderr: ""), onRun: nil)
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
        let reconstruction = try XCTUnwrap(finalMetadata.reconstruction, "Successful runs must persist a reconstruction summary.")
        let selectedCount = selectedImageNames(in: paths).count
        XCTAssertEqual(reconstruction.registeredImages, selectedCount)
        XCTAssertEqual(reconstruction.totalImages, selectedCount)
        XCTAssertEqual(
            reconstruction.mapper,
            "colmap"
        )
        XCTAssertEqual(
            reconstruction.meanReprojectionError,
            0,
            "Persisted reconstruction facts must use residuals recomputed from COLMAP tracks."
        )
        let geometry = try GeometryArtifactStore.load(
            from: paths.geometryManifestURL,
            projectPaths: paths
        )
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
                globalFramesRatio: 1.1,
                globalPointsRatio: 1.1,
                globalMaxRefinements: 5
            )
        )
        XCTAssertNil(geometry.mapping.fallbackReason)
        XCTAssertEqual(geometry.canonicalOrientation.status, .unresolved)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: paths.colmapSparseURL.path)
                .contains(where: { $0.hasPrefix(".orientation-candidate-") })
        )
        XCTAssertEqual(finalMetadata.geometryArtifact, geometry)
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
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Residual-validated mapper selection",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    detailProfile: .fast,
                    inputOrdering: .unordered,
                    photoSelection: .useAllValidPhotos
                )
            ),
            to: paths.metadataURL
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
                    stdout: "Registered images: 10 / 10\nPoints: 1\nObservations: 10\nMean track length: 10.0\nMean reprojection error: 0.4\n",
                    stderr: ""
                )
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_analyzer"],
                result: .init(
                    exitCode: 0,
                    terminationReason: .exit,
                    stdout: "Registered images: 9 / 10\nPoints: 1\nObservations: 9\nMean track length: 9.0\nMean reprojection error: 0.5\n",
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
        XCTAssertNotNil(events.stageLog(containing: "Rejected COLMAP model 0"))
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
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
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
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 30 / 30\nPoints: 1\nObservations: 30\nMean track length: 30.0\n", stderr: ""), onRun: nil),
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
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
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
                    stdout: "Registered images: 30 / 30\nPoints: 1\nObservations: 30\nMean track length: 30.0\nMean reprojection error: 0.5\n",
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
            XCTAssertEqual(
                error as? ColmapPairPlanningError,
                .disconnectedVerifiedGraph
            )
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


    func testConnectedFaissMappingMissRetriesSameScheduleWithExactMatching() async throws {
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
                pointCount: 1
            ) + [
            .init(
                path: fixture.toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { arguments in
                    XCTAssertEqual(
                        self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: arguments),
                        "1"
                    )
                    try self.writeVerifiedPairResults(for: arguments)
                }
            ),
            ] + successfulMappingScripts(
                colmapPath: fixture.toolchain.colmap.path,
                projectURL: fixture.projectURL,
                registeredViews: 8,
                totalViews: 8,
                pointCount: 1
            )
        )

        try await run.pipeline.run { _ in }

        let evidence = try PairGraphEvidenceStore.load(
            from: fixture.paths.pairGraphEvidenceURL,
            projectPaths: fixture.paths
        )
        XCTAssertEqual(evidence.attempts.map(\.artifact.matcher), [.faiss, .exact])
        XCTAssertEqual(
            evidence.attempts[0].scheduledPairs,
            evidence.attempts[1].scheduledPairs
        )
        XCTAssertFalse(run.runner.calls.contains { $0.1.first == "local_vocab_retriever" })
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
                mode: .sameScheduleExact,
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
                pointCount: 1
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
                pointCount: 1
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
        let workerExecution = try XCTUnwrap(finished.geometryArtifact?.workerExecution)
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
                pointCount: 1
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
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Interrupted classical matching",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    detailProfile: .fast,
                    inputOrdering: .unordered,
                    photoSelection: .useAllValidPhotos
                )
            ),
            to: paths.metadataURL
        )
        let toolchain = try makeToolchain(root: temp)
        let featureRunner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["feature_extractor"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { try? self.writeFeatureDatabase(for: $0) }
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
                    stdout: "Registered images: 8 / 8\nPoints: 1\nObservations: 8\nMean track length: 8.0\nMean reprojection error: 0.5\n",
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
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Bundle adjustment policy change",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    detailProfile: .fast,
                    inputOrdering: .unordered,
                    photoSelection: .useAllValidPhotos
                )
            ),
            to: paths.metadataURL
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
                    stdout: "Registered images: 8 / 8\nPoints: 1\nObservations: 8\nMean track length: 8.0\nMean reprojection error: 0.5\n",
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
                    stdout: "Registered images: 8 / 8\nPoints: 1\nObservations: 8\nMean track length: 8.0\nMean reprojection error: 0.5\n",
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
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Photo-only injected plan",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    detailProfile: .fast,
                    inputOrdering: .unordered,
                    photoSelection: .useAllValidPhotos
                )
            ),
            to: paths.metadataURL
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
                    stdout: "Registered images: 8 / 8\nPoints: 1\nObservations: 8\nMean track length: 8.0\nMean reprojection error: 0.5\n",
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
        let acceptedGeometry = try XCTUnwrap(completedMetadata.geometryArtifact)
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
        XCTAssertEqual(resumedMetadata.geometryArtifact, acceptedGeometry)
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
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Evidence-first plan change",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    detailProfile: .fast,
                    inputOrdering: .unordered,
                    photoSelection: .useAllValidPhotos
                )
            ),
            to: paths.metadataURL
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
                    stdout: "Registered images: 8 / 8\nPoints: 1\nObservations: 8\nMean track length: 8.0\nMean reprojection error: 0.5\n",
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
                    stdout: "Registered images: 8 / 8\nPoints: 1\nObservations: 8\nMean track length: 8.0\nMean reprojection error: 0.5\n",
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
        let resumedGeometry = try XCTUnwrap(resumedMetadata.geometryArtifact)
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

    func testFaissCrashOnDenserRetryUsesExactMatchingWithoutReextractingFeatures() async throws {
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
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
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
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: args), "0")
                    try? self.writeVerifiedPairResults(for: args, verifiedRows: 0)
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
                    stdout: "Registered images: 30 / 30\nPoints: 1\nObservations: 30\nMean track length: 30.0\nMean reprojection error: 0.5\n",
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
        XCTAssertEqual(commands.filter { $0 == "local_vocab_retriever" }.count, 2)
        XCTAssertEqual(commands.filter { $0 == "matches_importer" }.count, 3)
        XCTAssertNotNil(events.stageLog(containing: "preserving features and retrying with exact matching"))
        let geometry = try GeometryArtifactStore.load(
            from: paths.geometryManifestURL,
            projectPaths: paths
        )
        let attempts = try XCTUnwrap(geometry.pairGraph.measurement).matcherAttempts
        XCTAssertEqual(attempts.map(\.recoveryLevel), [.normal, .expanded, .expanded])
        XCTAssertEqual(attempts.map(\.matcher), [.faiss, .faiss, .exact])
    }

    func testExactMatchingContinuesDensityLadderWithoutReextractingFeatures() async throws {
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
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
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
                    stdout: "Registered images: 45 / 45\nPoints: 1\nObservations: 45\nMean track length: 45.0\nMean reprojection error: 0.5\n",
                    stderr: ""
                ),
                onRun: nil
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
        } catch {
            XCTFail("Pipeline failed after calls \(runner.calls): \(error)")
            return
        }

        let commands = runner.calls.compactMap { $0.1.first }
        XCTAssertEqual(commands.filter { $0 == "feature_extractor" }.count, 1)
        XCTAssertEqual(commands.filter { $0 == "local_vocab_retriever" }.count, 2)
        XCTAssertEqual(commands.filter { $0 == "matches_importer" }.count, 4)
        let geometry = try GeometryArtifactStore.load(
            from: paths.geometryManifestURL,
            projectPaths: paths
        )
        let attempts = try XCTUnwrap(geometry.pairGraph.measurement).matcherAttempts
        XCTAssertEqual(
            attempts.map(\.recoveryLevel),
            [.normal, .normal, .expanded, .maximum]
        )
        XCTAssertEqual(attempts.map(\.matcher), [.faiss, .exact, .exact, .exact])
    }

    func testPlanningFailureIsRetainedInAcceptedPairGraphEvidence() async throws {
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
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Planning evidence",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    detailProfile: .fast,
                    inputOrdering: .unordered,
                    photoSelection: .useAllValidPhotos
                )
            ),
            to: paths.metadataURL
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
                    stdout: "Registered images: 61 / 61\nPoints: 1\nObservations: 61\nMean track length: 61.0\nMean reprojection error: 0.5\n",
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
        XCTAssertEqual(measurement.matcherAttempts.count, 2)
        XCTAssertEqual(measurement.matcherAttempts.map(\.recoveryLevel), [.normal, .expanded])
        XCTAssertEqual(measurement.matcherAttempts.map(\.outcome), [.failed, .completed])
        XCTAssertEqual(measurement.matcherAttempts[0].scheduledPairCount, 0)
        XCTAssertEqual(measurement.matcherAttempts[0].attemptedPairCount, 0)
        XCTAssertEqual(
            measurement.matchingDurationSeconds,
            measurement.matcherAttempts.reduce(0) { $0 + $1.durationSeconds },
            accuracy: 1e-12
        )
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
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Repeated retrieval",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    detailProfile: .highDetail,
                    inputOrdering: .unordered,
                    photoSelection: .useAllValidPhotos
                )
            ),
            to: paths.metadataURL
        )
        let toolchain = try makeToolchain(root: temp)
        let lowQuality = "Registered images: 100 / 251\nPoints: 1\nObservations: 100\nMean track length: 100.0\nMean reprojection error: 0.5\n"
        let accepted = "Registered images: 251 / 251\nPoints: 1\nObservations: 251\nMean track length: 251.0\nMean reprojection error: 0.5\n"
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
                        if let first = queryNames.first, let last = queryNames.last {
                            pairs.append("\(first) \(last)")
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
        let geometry = try GeometryArtifactStore.load(
            from: paths.geometryManifestURL,
            projectPaths: paths
        )
        let attempts = try XCTUnwrap(geometry.pairGraph.measurement?.matcherAttempts)
        XCTAssertEqual(attempts.map(\.recoveryLevel), [.normal, .expanded, .maximum])
        XCTAssertEqual(attempts.map(\.matcher), [.faiss, .faiss, .faiss])
        XCTAssertEqual(attempts.map(\.outcome), [.completed, .failed, .completed])
    }

    func testContinuousMixedImageDimensionsUseSeparateCameras() async throws {
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
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        let toolchain = try makeToolchain(root: temp)
        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { try? self.writeFeatureDatabase(for: $0) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["local_vocab_retriever"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { try? self.writeVocabularyOutput(for: $0) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["matches_importer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { try? self.writeVerifiedPairResults(for: $0) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), stdoutLines: ["Retriangulation and Global bundle adjustment"], onRun: { _ in
                try? self.writeSparseModel(at: projectURL)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 30 / 30\nPoints: 1\nObservations: 30\nMean track length: 30.0\nMean reprojection error: 0.5\n", stderr: ""), onRun: nil),
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

        let featureCalls = runner.calls.filter { $0.1.first == "feature_extractor" }
        XCTAssertEqual(featureCalls.count, 1, "Calls: \(runner.calls)")
        for call in featureCalls {
            XCTAssertEqual(value(for: "--ImageReader.single_camera", in: call.1), "0")
        }
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
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
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
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "Registered images: 120 / 120\nPoints: 1\nObservations: 120\nMean track length: 120.0\n", stderr: ""), onRun: nil),
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
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

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
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

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
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

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
                    FileManager.default.createFile(atPath: out.appendingPathComponent("cameras.bin").path, contents: Data([0x01]))
                    FileManager.default.createFile(atPath: out.appendingPathComponent("images.bin").path, contents: Data([0x01]))
                    FileManager.default.createFile(atPath: out.appendingPathComponent("points3D.bin").path, contents: Data([0x01]))
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
            tooling: .init(runner: runner)
        )

        try await pipeline.run { _ in }

        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.msplat.path }))
        XCTAssertNotNil(msplatDatasetPath)
        let output = projectURL.appendingPathComponent("Output/splat.ply")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let completedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let plan = try XCTUnwrap(completedMetadata.resolvedRunPlan)
        let trainingArtifact = try XCTUnwrap(completedMetadata.trainingArtifact)
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
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: paths.trainingURL.appendingPathComponent("msplat_dataset").path
            )
        )
        XCTAssertEqual(
            try TrainingArtifactStore.load(
                from: paths.trainingManifestURL,
                projectPaths: paths
            ),
            completedMetadata.trainingArtifact
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
            requestedRunOptions: RequestedRunOptions(detailProfile: .fast),
            reconstruction: ReconstructionSummary(
                mapper: "colmap",
                capturedAt: Date(timeIntervalSince1970: 1),
                registeredImages: 3,
                totalImages: 3
            )
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        try FileManager.default.copyItem(
            at: sourcePhotos,
            to: paths.importedPhotosURL
        )
        var selectedMappings: [TestSelectedFrameMapping] = []
        for index in 0..<3 {
            let name = String(format: "frame_%06d.jpg", index)
            try writeTestImage(
                url: paths.framesSelectedURL.appendingPathComponent(name),
                value: UInt8(index)
            )
            selectedMappings.append(TestSelectedFrameMapping(
                outputFileName: name,
                groupId: "photos",
                isVideo: false
            ))
        }
        try JSONEncoder().encode(selectedMappings).write(
            to: paths.framesSelectedManifestURL,
            options: [.atomic]
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
        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            try Data([1]).write(to: sparse.appendingPathComponent(name))
        }
        try persistGeometryArtifactFixture(metadata: &metadata, paths: paths)
        let identitySparse = try makeMsplatIdentitySparseFixture(
            from: sparse,
            under: paths.trainingURL
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

        let toolchain = try makeToolchain(root: temp, createMsplatFile: true)
        let firstBacking = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["model_converter"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                guard let outputPath = self.value(for: "--output_path", in: args) else { return }
                let output = URL(fileURLWithPath: outputPath, isDirectory: true)
                FileManager.default.createFile(atPath: output.appendingPathComponent("cameras.bin").path, contents: Data([1]))
                FileManager.default.createFile(atPath: output.appendingPathComponent("images.bin").path, contents: Data([1]))
                FileManager.default.createFile(atPath: output.appendingPathComponent("points3D.bin").path, contents: Data([1]))
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
            tooling: .init(runner: cancellingRunner)
        )

        do {
            try await firstPipeline.run(resumeFrom: .sfmMapping) { _ in }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
        let interruptedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(interruptedMetadata.trainingArtifact?.completionStatus, .checkpointed)
        XCTAssertEqual(interruptedMetadata.trainingArtifact?.completedIteration, 500)
        XCTAssertEqual(interruptedMetadata.trainingArtifact?.checkpointDigest, receipt.payloadSHA256)
        XCTAssertEqual(interruptedMetadata.trainingArtifact?.peakMemoryBytes, receipt.peakMemoryBytes)
        XCTAssertEqual(interruptedMetadata.trainingArtifact?.memoryBudgetBytes, memoryBudgetBytes)
        XCTAssertEqual(interruptedMetadata.trainingArtifact?.rasterFallbackCount, 0)
        XCTAssertEqual(interruptedMetadata.trainingArtifact?.droppedIntersectionCount, 0)

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
                FileManager.default.createFile(atPath: output.appendingPathComponent("cameras.bin").path, contents: Data([1]))
                FileManager.default.createFile(atPath: output.appendingPathComponent("images.bin").path, contents: Data([1]))
                FileManager.default.createFile(atPath: output.appendingPathComponent("points3D.bin").path, contents: Data([1]))
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
            tooling: .init(runner: secondRunner)
        )

        try await secondPipeline.run(resumeFrom: .sfmMapping) { _ in }

        let trainingCalls = secondRunner.calls.filter { $0.0 == toolchain.msplat.path }
        XCTAssertEqual(trainingCalls.count, 2)
        XCTAssertEqual(value(for: "--resume", in: trainingCalls[0].1), paths.msplatCheckpointURL.path)
        XCTAssertNil(value(for: "--resume", in: trainingCalls[1].1))
        let completedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(completedMetadata.trainingArtifact?.completionStatus, .completed)
        XCTAssertEqual(completedMetadata.trainingArtifact?.completedIteration, 3_000)
        XCTAssertEqual(completedMetadata.trainingArtifact?.peakMemoryBytes, 536_870_912)
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
        try FileManager.default.copyItem(
            at: sourcePhotos,
            to: paths.importedPhotosURL
        )

        let selectedMappings = try (0..<3).map { index in
            let name = String(format: "frame_%06d.jpg", index)
            try writeTestImage(
                url: paths.framesSelectedURL.appendingPathComponent(name),
                value: UInt8(index * 40)
            )
            return TestSelectedFrameMapping(
                outputFileName: name,
                groupId: "photos",
                isVideo: false
            )
        }
        try JSONEncoder().encode(selectedMappings).write(
            to: paths.framesSelectedManifestURL,
            options: [.atomic]
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

        for name in ["cameras.bin", "images.bin", "points3D.bin"] {
            try Data([1]).write(to: sparse.appendingPathComponent(name))
        }
        let identitySparse = try makeMsplatIdentitySparseFixture(
            from: sparse,
            under: paths.trainingURL
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
            rasterFallbackCount: receipt.rasterFallbackCount,
            rasterExactFallbackElapsedSeconds: receipt.rasterExactFallbackElapsedSeconds,
            rasterExactBufferGrowthCount: receipt.rasterExactBufferGrowthCount,
            rasterExactBufferBytesAdded: receipt.rasterExactBufferBytesAdded,
            rasterReplayElapsedSeconds: receipt.rasterReplayElapsedSeconds,
            rasterPeakExactIntersectionCapacity: receipt.rasterPeakExactIntersectionCapacity,
            droppedIntersectionCount: receipt.droppedIntersectionCount,
            completionStatus: .checkpointed
        )
        var metadata = ProjectMetadata(
            title: "Balanced retry",
            input: .photos(folder: sourcePhotos.path),
            requestedRunOptions: RequestedRunOptions(detailProfile: .balanced),
            trainingArtifact: artifact,
            state: PipelineState(stage: .sfmMapping, lastError: nil),
            checkpoint: PipelineCheckpoint(
                stage: .trainSplat,
                details: .trainSplat(TrainSplatCheckpoint(
                    progressStep: receipt.iteration,
                    progressTotal: 7_000
                ))
            ),
            reconstruction: ReconstructionSummary(
                mapper: "colmap",
                capturedAt: Date(timeIntervalSince1970: 1),
                registeredImages: 3,
                totalImages: 3
            )
        )
        try persistGeometryArtifactFixture(metadata: &metadata, paths: paths)
        try TrainingArtifactStore.persist(artifact, metadata: &metadata, paths: paths)

        let toolchain = try makeToolchain(root: temp, createMsplatFile: true)
        let converterScript: () -> MockSubprocessRunner.Script = {
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["model_converter"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    guard let outputPath = self.value(for: "--output_path", in: args) else { return }
                    let output = URL(fileURLWithPath: outputPath, isDirectory: true)
                    FileManager.default.createFile(atPath: output.appendingPathComponent("cameras.bin").path, contents: Data([1]))
                    FileManager.default.createFile(atPath: output.appendingPathComponent("images.bin").path, contents: Data([1]))
                    FileManager.default.createFile(atPath: output.appendingPathComponent("points3D.bin").path, contents: Data([1]))
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
            tooling: .init(runner: failedRunner)
        )
        await XCTAssertThrowsErrorAsync {
            try await failedPipeline.run(resumeFrom: .sfmMapping) { _ in }
        }

        let failedMetadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertNotNil(failedMetadata.state.lastError)
        XCTAssertNil(failedMetadata.checkpoint)
        XCTAssertEqual(failedMetadata.trainingArtifact?.completionStatus, .checkpointed)

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
            tooling: .init(runner: retryRunner)
        )

        try await retryPipeline.run(resumeFrom: .sfmMapping) { _ in }

        let retryCall = try XCTUnwrap(retryRunner.calls.first(where: { $0.0 == toolchain.msplat.path }))
        XCTAssertEqual(value(for: "--resume", in: retryCall.1), paths.msplatCheckpointURL.path)
        XCTAssertEqual(
            try ProjectMetadataStore.load(from: paths.metadataURL)
                .trainingArtifact?.peakMemoryBytes,
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
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

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

    func testExplicitDa3CandidateRecordsAcceptedSmallFallback() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<3 {
            try writeTestImage(url: sourcePhotos.appendingPathComponent("img\(index).jpg"), value: UInt8(index % 255))
        }

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp, createDa3Files: true)

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.da3.sfmTool.path, argsPrefix: ["--images"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                do {
                    try self.writeDa3RunArtifacts(
                        for: args,
                        selectedModelSubdirectory: "DA3-SMALL"
                    )
                } catch {
                    XCTFail("Failed to write DA3 test artifacts: \(error)")
                }
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                XCTAssertEqual(self.value(for: "--ImageReader.single_camera", in: args), "0")
                XCTAssertEqual(self.value(for: "--ImageReader.camera_model", in: args), "SIMPLE_RADIAL")
                try? self.writeFeatureDatabase(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["matches_importer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
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
                    memoryGB: 48,
                    cpuCount: 16,
                    gpuWorkingSetGB: 36
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
        XCTAssertEqual(value(for: "--model-subdir", in: da3Args), "DA3-BASE")
        XCTAssertEqual(value(for: "--fallback-model-subdir", in: da3Args), "DA3-SMALL")
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "model_analyzer" }))
        XCTAssertTrue(runner.calls.contains(where: { $0.0 == toolchain.colmap.path && $0.1.first == "point_triangulator" }))
        let finished = try ProjectMetadataStore.load(from: paths.metadataURL)
        let geometry = try XCTUnwrap(finished.geometryArtifact)
        XCTAssertEqual(
            geometry.modelVersion,
            "DA3-SMALL@89abcdef0123456789abcdef0123456789abcdef"
        )
        XCTAssertEqual(geometry.provenance.runtime?.identifier, "da3_mps")
        XCTAssertEqual(geometry.provenance.model?.identifier, "DA3-SMALL")
        XCTAssertEqual(
            geometry.provenance.model?.payloadSHA256,
            try GeometryArtifactStore.sha256(
                of: toolchain.da3.fallbackModelBundle.appendingPathComponent("model.safetensors")
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
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast)
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
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
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["matches_importer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: nil),
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
        let finished = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertNil(finished.reconstruction)
        XCTAssertNil(finished.geometryArtifact)
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
                inputOrdering: .continuous,
                photoSelection: .useAllValidPhotos
            )
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

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
        XCTAssertEqual(finished.reconstruction?.mapper, "da3-refined")
        XCTAssertEqual(
            finished.reconstruction?.meanReprojectionError,
            0,
            "Persisted reconstruction facts must use residuals recomputed from COLMAP tracks."
        )
        let geometry = try XCTUnwrap(finished.geometryArtifact)
        XCTAssertEqual(geometry.pairGraph.status, .notEvaluated)
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
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "DA3 cancellation",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    capturePath: .orbit,
                    detailProfile: .fast
                )
            ),
            to: paths.metadataURL
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

    func testDa3RefinementFaissCrashRetriesExactWithoutReextractingFeatures() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Da3FaissRecovery.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)
        for index in 0..<29 {
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
                inputOrdering: .continuous,
                photoSelection: .useAllValidPhotos
            )
        )
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

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
                }
            ),
            .init(
                path: toolchain.colmap.path,
                argsPrefix: ["matches_importer"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in
                    XCTAssertEqual(self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: args), "1")
                    XCTAssertEqual(try? self.databaseRowCount("descriptors", at: paths.colmapDatabaseURL), 29)
                    XCTAssertEqual(try? self.databaseRowCount("keypoints", at: paths.colmapDatabaseURL), 29)
                    XCTAssertEqual(try? self.databaseRowCount("matches", at: paths.colmapDatabaseURL), 0)
                    XCTAssertEqual(try? self.databaseRowCount("two_view_geometries", at: paths.colmapDatabaseURL), 0)
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
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Interrupted DA3 matching",
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    capturePath: .orbit,
                    detailProfile: .fast,
                    inputOrdering: .continuous,
                    photoSelection: .useAllValidPhotos
                )
            ),
            to: paths.metadataURL
        )

        let toolchain = try makeToolchain(root: temp, createDa3Files: true)
        let seedRunner = MockSubprocessRunner(scripts: [
            .init(
                path: toolchain.da3.sfmTool.path,
                argsPrefix: ["--images"],
                result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""),
                onRun: { args in try? self.writeDa3RunArtifacts(for: args) }
            )
        ])
        let seedPipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(
                toolchain: toolchain,
                candidateRoute: .da3,
                skipTraining: true,
                stopAfterStage: .sfmFeatures
            ),
            tooling: .init(runner: seedRunner)
        )
        try await seedPipeline.run { _ in }

        try? FileManager.default.removeItem(at: paths.colmapDatabaseURL)
        try writeFeatureDatabase(for: [
            "--database_path", paths.colmapDatabaseURL.path,
            "--image_path", paths.framesSelectedURL.path,
        ])
        try writePartialMatchRows(at: paths.colmapDatabaseURL)
        try markMatchingAsInterrupted(paths: paths)
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
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let toolchain = try makeToolchain(root: temp)
        let belowCoverageReport = """
        Registered images: 2 / 3
        Points: 100
        Observations: 200
        Mean track length: 2.0
        Mean reprojection error: 0.8
        """

        let runner = MockSubprocessRunner(scripts: [
            .init(path: toolchain.colmap.path, argsPrefix: ["feature_extractor"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { try? self.writeFeatureDatabase(for: $0) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["matches_importer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { try? self.writeVerifiedPairResults(for: $0) }),
            .init(path: toolchain.colmap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in
                try? self.writeSparseModel(at: projectURL, registeredImageCount: 2, pointCount: 100)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: belowCoverageReport, stderr: ""), onRun: nil),
            .init(path: toolchain.colmap.path, argsPrefix: ["matches_importer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { args in
                XCTAssertEqual(self.value(for: "--SiftMatching.cpu_brute_force_matcher", in: args), "1")
                try? self.writeVerifiedPairResults(for: args)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["mapper"], result: .init(exitCode: 0, terminationReason: .exit, stdout: "", stderr: ""), onRun: { _ in
                try? self.writeSparseModel(at: projectURL, registeredImageCount: 2, pointCount: 100)
            }),
            .init(path: toolchain.colmap.path, argsPrefix: ["model_analyzer"], result: .init(exitCode: 0, terminationReason: .exit, stdout: belowCoverageReport, stderr: ""), onRun: nil),
        ])

        let pipeline = PipelineRunner(
            projectURL: projectURL,
            config: makePipelineConfig(toolchain: toolchain, candidateRoute: .colmap),
            tooling: .init(runner: runner)
        )

        await XCTAssertThrowsErrorAsync {
            try await pipeline.run { _ in }
        }

        let featureRuns = runner.calls.filter { $0.0 == toolchain.colmap.path && $0.1.first == "feature_extractor" }
        XCTAssertEqual(featureRuns.count, 1)
        XCTAssertEqual(runner.calls.filter { $0.1.first == "matches_importer" }.count, 2)
        XCTAssertEqual(runner.calls.filter { $0.1.first == "mapper" }.count, 2)
        XCTAssertEqual(runner.calls.filter { $0.1.first == "model_analyzer" }.count, 2)
    }

    func testPipelineFailsOnMissingImages() async throws {
        let temp = makeTempRoot()
        let projectURL = temp.appendingPathComponent("Test.easysplatproj", isDirectory: true)
        let sourcePhotos = temp.appendingPathComponent("SourcePhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcePhotos, withIntermediateDirectories: true)

        let metadata = ProjectMetadata(title: "Test",
                                       input: .photos(folder: sourcePhotos.path),
                                       requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .fast))
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

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
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

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
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

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
        pointCount: Int = 1
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
            pointCount: pointCount
        )
    }

    private func writeSparseModel(at modelURL: URL, imageName: String) throws {
        try writeSparseModel(at: modelURL, imageNames: [imageName])
    }

    private func writeSparseModel(at modelURL: URL, imageNames: [String]) throws {
        let safeImageNames = imageNames.isEmpty ? ["frame_000000.jpg"] : imageNames
        try writeDa3SparseModel(
            at: modelURL,
            imageNames: safeImageNames,
            pointCount: 1
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

    private func writeFeatureDatabase(for arguments: [String]) throws {
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
        CREATE TABLE cameras(camera_id INTEGER PRIMARY KEY);
        CREATE TABLE images(
            image_id INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE,
            camera_id INTEGER NOT NULL
        );
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
        INSERT INTO cameras(camera_id) VALUES (1);
        """
        try executeSQL(schema, in: database)

        var imageStatement: OpaquePointer?
        var keypointStatement: OpaquePointer?
        var descriptorStatement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "INSERT INTO images(image_id, name, camera_id) VALUES (?, ?, 1);",
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
        let imageStatement,
        let keypointStatement,
        let descriptorStatement else {
            throw NSError(domain: "PipelineIntegrationTests", code: 12)
        }
        defer {
            sqlite3_finalize(imageStatement)
            sqlite3_finalize(keypointStatement)
            sqlite3_finalize(descriptorStatement)
        }
        try executeSQL("BEGIN IMMEDIATE TRANSACTION;", in: database)
        do {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (offset, imageName) in imageNames.enumerated() {
                let imageID = Int32(offset + 1)
                sqlite3_bind_int(imageStatement, 1, imageID)
                sqlite3_bind_text(imageStatement, 2, imageName, -1, transient)
                guard sqlite3_step(imageStatement) == SQLITE_DONE else {
                    throw NSError(domain: "PipelineIntegrationTests", code: 13)
                }
                sqlite3_reset(imageStatement)
                sqlite3_clear_bindings(imageStatement)
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
        guard let outputPath = value(for: "--output_pair_list_path", in: arguments) else {
            throw NSError(domain: "PipelineIntegrationTests", code: 15)
        }
        let queryNames: [String]
        if connectQueries,
           let queryPath = value(for: "--query_image_list_path", in: arguments) {
            queryNames = try String(contentsOfFile: queryPath, encoding: .utf8)
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
        } else {
            queryNames = []
        }
        let lines = pairLines.isEmpty
            ? zip(queryNames, queryNames.dropFirst()).map { "\($0.0) \($0.1)" }
            : pairLines
        let text = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try text.write(
            to: URL(fileURLWithPath: outputPath),
            atomically: true,
            encoding: .utf8
        )
    }

    private func makePhotoRecoveryProject(
        in root: URL,
        name: String,
        photoCount: Int = 60,
        inputOrdering: InputOrdering = .unordered,
        photoSelection: PhotoSelection = .useAllValidPhotos
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
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: name,
                input: .photos(folder: sourcePhotos.path),
                requestedRunOptions: RequestedRunOptions(
                    detailProfile: .fast,
                    inputOrdering: inputOrdering,
                    photoSelection: photoSelection
                )
            ),
            to: paths.metadataURL
        )
        return (projectURL, paths, try makeToolchain(root: root))
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
        paths: ProjectPaths
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
        let workerExecution = makeGeometryWorkerExecutionArtifact(
            resolvedBudget: workerBudget
        )
        _ = try GeometryWorkerExecutionArtifactStore.save(
            workerExecution,
            to: GeometryWorkerExecutionArtifactStore.canonicalURL(for: paths),
            expectedBudget: workerBudget,
            projectPaths: paths
        )
        let modelURL = paths.colmapSparseURL.appendingPathComponent("0", isDirectory: true)
        let residuals = try ColmapResidualAnalyzer.analyze(modelDirectory: modelURL)
        let imageNames = residuals.registeredImageNames.sorted()
        let modelHashes = try Dictionary(uniqueKeysWithValues: [
            "cameras.txt",
            "images.txt",
            "points3D.txt",
        ].map { name in
            (name, try GeometryArtifactStore.sha256(of: modelURL.appendingPathComponent(name)))
        })
        let pairGraphEvidence = try persistPairGraphEvidenceFixture(
            paths: paths,
            imageNames: imageNames
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
            cameraModel: "SIMPLE_PINHOLE",
            cameraGrouping: .automatic,
            registeredViewCount: residuals.registeredViewCount,
            totalViewCount: imageNames.count,
            trackCount: residuals.observationCount,
            pointCount: residuals.pointCount,
            residualProvenance: residuals.provenance,
            medianPixelResidual: residuals.medianPixelResidual,
            p90PixelResidual: residuals.p90PixelResidual,
            timings: [
                PipelineStage.sfmMapping.rawValue: 1,
                "orientation_estimation_seconds": 0.001,
            ],
            peakMemoryBytes: 1,
            modelHashes: modelHashes,
            fallbackReason: nil,
            provenance: GeometryProvenance(
                toolchainVersion: "test-toolchain",
                solver: GeometryComponentProvenance(
                    identifier: "colmap",
                    version: "test",
                    revision: "test",
                    payloadSHA256: String(repeating: "a", count: 64)
                ),
                runtime: nil,
                model: nil
            ),
            workerExecution: workerExecution,
            pairGraph: try pairGraphEvidence.pairGraphArtifact(),
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
        try ColmapFeatureEvidenceStore.save(
            ColmapFeatureEvidence(
                selectedFramesDigest: try GeometryArtifactStore.selectedFramesDigest(
                    orderedImageNames: imageNames,
                    projectPaths: paths
                ),
                imageNames: imageNames,
                featureDatabaseDigest: try ColmapDatabaseDigester
                    .digests(at: paths.colmapDatabaseURL).feature
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

        try writeDa3PoseSeed(
            at: URL(fileURLWithPath: out),
            imageNames: imageNames.isEmpty ? [imageName] : imageNames
        )

        let manifest = Da3CoverageManifest(
            mode: "seed_refine",
            requestedDevice: value(for: "--device", in: args) ?? "mps",
            selectedDevice: "mps",
            modelSubdirectory: selectedModelSubdirectory
                ?? value(for: "--model-subdir", in: args)
                ?? "DA3-BASE",
            fallbackModelSubdirectory: value(for: "--fallback-model-subdir", in: args),
            processResolution: Int(value(for: "--process-res", in: args) ?? "") ?? 504,
            cameraType: value(for: "--camera-type", in: args) ?? "PINHOLE",
            sharedCamera: args.contains("--shared-camera"),
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

    private func writeDa3PoseSeed(at modelURL: URL, imageNames: [String]) throws {
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try "1 SIMPLE_PINHOLE 640 480 500 320 240\n"
            .write(to: modelURL.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)
        let imagesText = imageNames.enumerated()
            .map { offset, name in "\(offset + 1) 1 0 0 0 0 0 0 1 \(name)\n" }
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
        let text = try String(contentsOf: imagesURL, encoding: .utf8)
            .replacingOccurrences(of: "320 240 ", with: "400 240 ")
        try text.write(to: imagesURL, atomically: true, encoding: .utf8)
    }

    private func writeDa3SparseModel(at modelURL: URL, imageNames: [String], pointCount: Int) throws {
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try "1 SIMPLE_PINHOLE 640 480 500 320 240\n"
            .write(to: modelURL.appendingPathComponent("cameras.txt"), atomically: true, encoding: .utf8)

        var imagesText = "# Image list with two lines per image:\n"
        for (offset, imageName) in imageNames.enumerated() {
            let imageID = offset + 1
            imagesText += "\(imageID) 1 0 0 0 0 0 0 1 \(imageName)\n"
            let observations = (1...pointCount)
                .map { pointID in "320 240 \(pointID)" }
                .joined(separator: " ")
            imagesText += observations + "\n"
        }
        try imagesText.write(to: modelURL.appendingPathComponent("images.txt"), atomically: true, encoding: .utf8)

        let points = (1...pointCount)
            .map { pointID in
                let point2DIndex = pointID - 1
                let track = imageNames.enumerated()
                    .map { offset, _ in "\(offset + 1) \(point2DIndex)" }
                    .joined(separator: " ")
                return "\(pointID) 0 0 1 128 128 128 1.0 \(track)"
            }
            .joined(separator: "\n")
        try (points + "\n").write(to: modelURL.appendingPathComponent("points3D.txt"), atomically: true, encoding: .utf8)
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
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)

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
          "source_version": "4.1.0",
          "source_commit": "fa8e3b3ff591552855f8ad2806723c80f963f69c",
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
        under root: URL
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
            .unresolved(
                openingViewDirection: CanonicalDirection(x: 0, y: 0, z: -1)
            ),
            to: sparse
        )
        return sparse
    }

    private func makeTempRoot() -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: temp)
        }
        return temp
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

#endif
