import XCTest
@testable import EasySplatCore

final class ProjectMetadataStoreTests: XCTestCase {
    func testRoundTripMetadata() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")

        let state = PipelineState(stage: .sfmMatching, attempt: 2, lastError: "boom", resumeToken: "token")
        let output = OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
        let checkpoint = PipelineCheckpoint(
            stage: .trainSplat,
            updatedAt: Date(timeIntervalSince1970: 123460),
            progressFraction: 0.5,
            message: "heartbeat",
            details: .trainSplat(TrainSplatCheckpoint(
                latestExportStep: 1000,
                latestExportPath: "/tmp/export_01000.ply",
                progressStep: 1200,
                progressTotal: 40000,
                stepsPerSecond: 1.2,
                resumeSnapshotPath: "/tmp/latest_snapshot.ply"
            ))
        )
        let completedSfmMapping = SfmMappingCheckpoint(
            mapper: "vggt",
            sparsePath: "SfM/colmap/sparse/0",
            registeredImages: 12
        )
        let metadata = ProjectMetadata(
            formatVersion: ProjectMetadataStore.supportedFormatVersion,
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 123456),
            title: "Test",
            input: .mixed(videos: ["/tmp/a.mov"], photosFolder: "/tmp/photos"),
            preset: PresetSpec(mode: .room, quality: .ultra),
            state: state,
            outputs: output,
            checkpoint: checkpoint,
            completedSfmMapping: completedSfmMapping,
            recoveryPromptSuppressed: true,
            lastRunStartedAt: Date(timeIntervalSince1970: 123499)
        )

        try ProjectMetadataStore.save(metadata, to: url)
        let loaded = try ProjectMetadataStore.load(from: url)

        XCTAssertEqual(loaded.formatVersion, metadata.formatVersion)
        XCTAssertEqual(loaded.id, metadata.id)
        XCTAssertEqual(loaded.createdAt, metadata.createdAt)
        XCTAssertEqual(loaded.title, metadata.title)
        XCTAssertEqual(loaded.preset.mode, metadata.preset.mode)
        XCTAssertEqual(loaded.preset.quality, metadata.preset.quality)
        XCTAssertEqual(loaded.state.stage, metadata.state.stage)
        XCTAssertEqual(loaded.state.attempt, metadata.state.attempt)
        XCTAssertEqual(loaded.state.lastError, metadata.state.lastError)
        XCTAssertEqual(loaded.state.resumeToken, metadata.state.resumeToken)
        XCTAssertEqual(loaded.outputs?.splatPlyPath, metadata.outputs?.splatPlyPath)
        XCTAssertEqual(loaded.outputs?.colmapModelPath, metadata.outputs?.colmapModelPath)
        XCTAssertEqual(loaded.checkpoint?.stage, metadata.checkpoint?.stage)
        XCTAssertEqual(loaded.checkpoint?.message, metadata.checkpoint?.message)
        XCTAssertEqual(loaded.completedSfmMapping?.mapper, completedSfmMapping.mapper)
        XCTAssertEqual(loaded.completedSfmMapping?.sparsePath, completedSfmMapping.sparsePath)
        XCTAssertEqual(loaded.completedSfmMapping?.registeredImages, completedSfmMapping.registeredImages)
        XCTAssertEqual(loaded.recoveryPromptSuppressed, true)
        XCTAssertEqual(loaded.lastRunStartedAt, Date(timeIntervalSince1970: 123499))
        if case let .trainSplat(details)? = loaded.checkpoint?.details {
            XCTAssertEqual(details.progressStep, 1_200)
            XCTAssertEqual(details.progressTotal, 40_000)
            XCTAssertNil(details.latestExportStep)
        } else {
            XCTFail("Expected trainSplat checkpoint details")
        }
    }

    func testLoadRejectsFutureFormatVersion() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")

        let future = """
        {
          "createdAt":"1970-01-01T00:00:00Z",
          "formatVersion":\(ProjectMetadataStore.supportedFormatVersion + 1),
          "id":"00000000-0000-0000-0000-000000000002",
          "input":{"photos":{"folder":"/tmp/photos"}},
          "preset":{"mode":"object","quality":"standard"},
          "state":{"attempt":0,"lastError":null,"resumeToken":null,"stage":"importInput"},
          "title":"Future"
        }
        """
        try future.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ProjectMetadataStore.load(from: url)) { error in
            guard case ProjectMetadataStore.LoadError.unsupportedFormatVersion(let v) = error else {
                XCTFail("Expected unsupportedFormatVersion, got \(error)")
                return
            }
            XCTAssertEqual(v, ProjectMetadataStore.supportedFormatVersion + 1)
        }
    }

    /// Regression: a future EasySplat may rename or drop fields that today's strict
    /// ProjectMetadata decoder requires. The formatVersion check must fire BEFORE the
    /// strict decode, otherwise such projects throw a generic DecodingError and silently
    /// disappear from the listing instead of being surfaced as "needs app update".
    func testLoadRejectsFutureFormatVersionEvenWithMissingRequiredFields() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")

        // Intentionally omit `state`, `input`, `preset`, `title`, `id`, `createdAt`. Today's
        // strict decoder rejects this. The version check must still take precedence.
        let future = """
        {
          "formatVersion":\(ProjectMetadataStore.supportedFormatVersion + 1),
          "newRequiredFieldFromFuture":"hello"
        }
        """
        try future.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ProjectMetadataStore.load(from: url)) { error in
            guard case ProjectMetadataStore.LoadError.unsupportedFormatVersion(let v) = error else {
                XCTFail("Expected unsupportedFormatVersion even with missing fields, got \(error)")
                return
            }
            XCTAssertEqual(v, ProjectMetadataStore.supportedFormatVersion + 1)
        }
    }

    func testLoadLegacyMetadataWithoutCheckpoint() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")

        let legacy = """
        {
          "createdAt":"1970-01-01T00:00:00Z",
          "formatVersion":1,
          "id":"00000000-0000-0000-0000-000000000001",
          "input":{"photos":{"folder":"/tmp/photos"}},
          "preset":{"mode":"object","quality":"standard"},
          "state":{"attempt":0,"lastError":null,"resumeToken":null,"stage":"importInput"},
          "title":"Legacy"
        }
        """
        try legacy.write(to: url, atomically: true, encoding: .utf8)
        let loaded = try ProjectMetadataStore.load(from: url)
        XCTAssertNil(loaded.checkpoint)
        XCTAssertNil(loaded.completedSfmMapping)
        XCTAssertNil(loaded.recoveryPromptSuppressed)
        XCTAssertNil(loaded.lastRunStartedAt)
        XCTAssertNil(loaded.reconstruction)
    }

    func testLoadDropsPreCheckpointVersionTwoTrainingArtifactWithoutLosingOutput() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let legacyVersionTwo = """
        {
          "createdAt":"1970-01-01T00:00:00Z",
          "formatVersion":2,
          "id":"00000000-0000-0000-0000-000000000003",
          "input":{"photos":{"folder":"/tmp/photos"}},
          "outputs":{"colmapModelPath":"SfM/colmap/sparse/0","splatPlyPath":"Output/splat.ply"},
          "preset":{"mode":"object","quality":"standard"},
          "state":{"attempt":0,"lastError":null,"resumeToken":null,"stage":"done"},
          "title":"Early v2",
          "trainingArtifact":{
            "completionStatus":"completed",
            "detailProfile":"balanced",
            "deterministicSeed":42,
            "elapsedSeconds":12.5,
            "gaussianCount":1250,
            "geometryDigest":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            "iterationLimit":7000,
            "outputPath":"Training/msplat/splat.ply",
            "peakMemoryBytes":2147483648,
            "plateauWindow":800,
            "runtimeVersion":"native-metal-cli-v1",
            "trainerVersion":"1.1.3 (git 106499b)"
          }
        }
        """
        try legacyVersionTwo.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try ProjectMetadataStore.load(from: url)

        XCTAssertNil(loaded.trainingArtifact)
        XCTAssertEqual(loaded.outputs?.splatPlyPath, "Output/splat.ply")
        XCTAssertEqual(loaded.outputs?.colmapModelPath, "SfM/colmap/sparse/0")
        XCTAssertEqual(loaded.state.stage, .done)
    }

    func testRoundTripPreservesNotes() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let metadata = ProjectMetadata(
            title: "With Notes",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard),
            notes: "First test in afternoon light"
        )
        try ProjectMetadataStore.save(metadata, to: url)
        let loaded = try ProjectMetadataStore.load(from: url)
        XCTAssertEqual(loaded.notes, "First test in afternoon light")
    }

    func testSavePreservingUserEditableFieldsKeepsNewerTitleAndNotesOnDisk() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let pipelineSnapshot = ProjectMetadata(
            title: "Race",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard),
            state: PipelineState(stage: .importInput, attempt: 0, lastError: nil, resumeToken: nil),
            notes: nil
        )
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Client-facing name",
                input: .photos(folder: "/tmp/photos"),
                preset: PresetSpec(mode: .object, quality: .standard),
                notes: "newer note from user"
            ),
            to: url
        )

        var stalePipelineWrite = pipelineSnapshot
        stalePipelineWrite.state = PipelineState(stage: .sfmFeatures, attempt: 0, lastError: nil, resumeToken: nil)
        try ProjectMetadataStore.savePreservingUserEditableFields(stalePipelineWrite, to: url)

        let loaded = try ProjectMetadataStore.load(from: url)
        XCTAssertEqual(loaded.state.stage, .sfmFeatures)
        XCTAssertEqual(loaded.title, "Client-facing name")
        XCTAssertEqual(loaded.notes, "newer note from user")
    }

    func testSavePreservingUserEditableFieldsDoesNotOverwriteFutureMetadata() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let stalePipelineMetadata = ProjectMetadata(
            title: "Stale pipeline title",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard)
        )
        let futureData = Data("""
        {
          "formatVersion":\(ProjectMetadataStore.supportedFormatVersion + 1),
          "newRequiredField":"keep this"
        }
        """.utf8)
        try futureData.write(to: url, options: [.atomic])

        XCTAssertThrowsError(
            try ProjectMetadataStore.savePreservingUserEditableFields(
                stalePipelineMetadata,
                to: url
            )
        )
        XCTAssertEqual(try Data(contentsOf: url), futureData)
    }

    func testSavePreservingUserEditableFieldsCreatesMissingMetadataFile() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let metadata = ProjectMetadata(
            title: "First write",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard)
        )

        try ProjectMetadataStore.savePreservingUserEditableFields(metadata, to: url)

        XCTAssertEqual(try ProjectMetadataStore.load(from: url).title, "First write")
    }

    func testMetadataStoreRejectsSymlinkedProjectRootWithoutWritingTarget() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let outsideProject = parent.appendingPathComponent("Outside.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideProject, withIntermediateDirectories: true)
        let outsideMetadataURL = outsideProject.appendingPathComponent("project.json")
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Outside",
                input: .photos(folder: "/tmp/photos"),
                preset: PresetSpec(mode: .object, quality: .standard)
            ),
            to: outsideMetadataURL
        )
        let originalBytes = try Data(contentsOf: outsideMetadataURL)

        let projectBase = parent.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projectBase, withIntermediateDirectories: true)
        let linkedProject = projectBase.appendingPathComponent("Linked.easysplatproj", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedProject,
            withDestinationURL: outsideProject
        )
        let linkedMetadataURL = linkedProject.appendingPathComponent("project.json")

        XCTAssertThrowsError(try ProjectMetadataStore.load(from: linkedMetadataURL))
        XCTAssertThrowsError(
            try ProjectMetadataStore.save(
                ProjectMetadata(
                    title: "Should not land outside",
                    input: .photos(folder: "/tmp/photos"),
                    preset: PresetSpec(mode: .object, quality: .standard)
                ),
                to: linkedMetadataURL
            )
        )
        XCTAssertEqual(try Data(contentsOf: outsideMetadataURL), originalBytes)
    }

    func testSerializedMutationCannotBeOverwrittenByPipelinePreservation() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let initial = ProjectMetadata(
            title: "Original",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard),
            state: PipelineState(stage: .importInput, attempt: 0, lastError: nil, resumeToken: nil),
            notes: "old note"
        )
        try ProjectMetadataStore.save(initial, to: url)

        let mutationEntered = DispatchSemaphore(value: 0)
        let releaseMutation = DispatchSemaphore(value: 0)
        let mutationFinished = DispatchSemaphore(value: 0)
        let preservationStarted = DispatchSemaphore(value: 0)
        let preservationFinished = DispatchSemaphore(value: 0)
        let errors = LockedErrors()

        DispatchQueue.global().async {
            defer { mutationFinished.signal() }
            do {
                _ = try ProjectMetadataStore.update(at: url) { metadata in
                    metadata.title = "Client-facing name"
                    metadata.notes = "final keystroke"
                    mutationEntered.signal()
                    releaseMutation.wait()
                }
            } catch {
                errors.append(error)
            }
        }
        XCTAssertEqual(mutationEntered.wait(timeout: .now() + 2), .success)

        var stalePipelineWrite = initial
        stalePipelineWrite.state = PipelineState(
            stage: .sfmFeatures,
            attempt: 0,
            lastError: nil,
            resumeToken: nil
        )
        let pipelineWrite = stalePipelineWrite
        DispatchQueue.global().async {
            preservationStarted.signal()
            defer { preservationFinished.signal() }
            do {
                try ProjectMetadataStore.savePreservingUserEditableFields(
                    pipelineWrite,
                    to: url
                )
            } catch {
                errors.append(error)
            }
        }
        XCTAssertEqual(preservationStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(
            preservationFinished.wait(timeout: .now() + 0.1),
            .timedOut,
            "Pipeline preservation must wait for the in-flight user mutation."
        )
        releaseMutation.signal()
        XCTAssertEqual(mutationFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(preservationFinished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(errors.values.isEmpty, "Unexpected metadata errors: \(errors.values)")

        let loaded = try ProjectMetadataStore.load(from: url)
        XCTAssertEqual(loaded.title, "Client-facing name")
        XCTAssertEqual(loaded.notes, "final keystroke")
        XCTAssertEqual(loaded.state.stage, .sfmFeatures)
    }

    func testSaveRejectsMetadataThatWouldExceedLoadLimitAndPreservesCurrentFile() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let initial = ProjectMetadata(
            title: "Readable",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard),
            notes: "keep me"
        )
        try ProjectMetadataStore.save(initial, to: url)
        let originalBytes = try Data(contentsOf: url)

        var oversized = initial
        oversized.notes = String(repeating: "x", count: 8 * 1_024 * 1_024)

        XCTAssertThrowsError(try ProjectMetadataStore.save(oversized, to: url))
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
        XCTAssertEqual(try ProjectMetadataStore.load(from: url).notes, "keep me")
    }

    func testLoadRejectsOversizedOrSymlinkedProjectMetadata() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadataURL = root.appendingPathComponent("project.json")
        try Data(repeating: 0x20, count: 8 * 1_024 * 1_024 + 1).write(to: metadataURL)

        XCTAssertThrowsError(try ProjectMetadataStore.load(from: metadataURL))

        try FileManager.default.removeItem(at: metadataURL)
        let outside = root.appendingPathComponent("outside.json")
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Outside",
                input: .photos(folder: "/tmp/photos"),
                preset: PresetSpec(mode: .object, quality: .standard)
            ),
            to: outside
        )
        try FileManager.default.createSymbolicLink(
            at: metadataURL,
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try ProjectMetadataStore.load(from: metadataURL))
    }

    func testRoundTripPreservesReconstructionSummary() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")

        let captured = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = ReconstructionSummary(
            mapper: "da3-direct",
            capturedAt: captured,
            registeredImages: 27,
            totalImages: 30,
            meanReprojectionError: 0.85,
            pointCount: 14_231,
            observationCount: 56_789,
            meanTrackLength: 4.0
        )
        let metadata = ProjectMetadata(
            title: "With Summary",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard),
            reconstruction: summary
        )

        try ProjectMetadataStore.save(metadata, to: url)
        let loaded = try ProjectMetadataStore.load(from: url)

        XCTAssertEqual(loaded.reconstruction, summary)
        XCTAssertEqual(loaded.reconstruction?.registeredFraction ?? -1, 27.0 / 30.0, accuracy: 1e-9)
    }
}

private final class LockedErrors: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Error] = []

    var values: [Error] {
        lock.withLock { storage }
    }

    func append(_ error: Error) {
        lock.withLock { storage.append(error) }
    }
}

final class ProjectMetadataFullSchemaRoundTripTests: XCTestCase {
    /// Regression guard for the current write contract. Legacy analytics and
    /// activity fields still decode, but a normal save must not write them back.
    func testRoundTripPreservesCurrentFieldsAndOmitsDecodeOnlyLegacyFields() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")

        let reconstruction = ReconstructionSummary(
            mapper: "global_mapper-gpu",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_500),
            registeredImages: 28,
            totalImages: 30,
            meanReprojectionError: 0.81,
            pointCount: 18_245,
            observationCount: 71_022,
            meanTrackLength: 3.9
        )
        let stageTimings: [StageTimingRecord] = [
            .init(stage: .sfmFeatures, startedAt: Date(timeIntervalSince1970: 1_700_000_100), durationSeconds: 45),
            .init(stage: .sfmMapping, startedAt: Date(timeIntervalSince1970: 1_700_000_200), durationSeconds: 120),
            .init(stage: .trainSplat, startedAt: Date(timeIntervalSince1970: 1_700_000_400), durationSeconds: 600)
        ]
        let autoTune = AutoTuneSnapshot(
            tier: "High",
            memoryGB: 48,
            cpuCount: 16,
            gpuWorkingSetGB: 32,
            mapAnythingResolution: 518,
            mapAnythingDirectViewLimit: 8,
            mapAnythingAnchorMaxViews: 64,
            mapAnythingWindowSize: 8,
            mapAnythingWindowOverlap: 2,
            vggtImageLoadResolution: 1280,
            vggtFixedResolution: 518,
            vggtMaxPoints: 150_000,
            vggtAllowed: true,
            colmapMaxNumFeatures: 10_000,
            colmapMaxNumMatches: 10_000,
            colmapSequentialOverlap: 12,
            colmapExhaustiveBlockSize: 25,
            threadCap: 8,
            colmapMaxImageSizeCap: nil,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let metadata = ProjectMetadata(
            formatVersion: ProjectMetadataStore.supportedFormatVersion,
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            createdAt: Date(timeIntervalSince1970: 1_699_999_000),
            title: "Full schema",
            input: .mixed(videos: ["/tmp/a.mov"], photosFolder: "/tmp/photos"),
            preset: PresetSpec(mode: .room, quality: .ultra),
            state: PipelineState(stage: .done, attempt: 1, lastError: nil, resumeToken: nil),
            outputs: OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0"),
            checkpoint: nil,
            completedSfmMapping: SfmMappingCheckpoint(mapper: "global_mapper-gpu", sparsePath: "SfM/colmap/sparse/0", registeredImages: 28),
            recoveryPromptSuppressed: false,
            lastRunStartedAt: nil,
            shareMetrics: ShareMetrics(shareClickedCount: 2, shareCompletedCount: 1, lastShareService: "AirDrop", lastSharedAt: Date(timeIntervalSince1970: 1_700_000_900)),
            reconstruction: reconstruction,
            stageTimings: stageTimings,
            autoTune: autoTune,
            notes: "captured under window light",
            lastOpenedAt: Date(timeIntervalSince1970: 1_700_001_000),
            lastFailureAt: Date(timeIntervalSince1970: 1_699_999_500)
        )

        try ProjectMetadataStore.save(metadata, to: url)
        let saved = try Data(contentsOf: url)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        XCTAssertNil(object["autoTune"])
        XCTAssertNil(object["shareMetrics"])
        XCTAssertNil(object["lastOpenedAt"])
        let loaded = try ProjectMetadataStore.load(from: url)

        XCTAssertEqual(loaded.reconstruction, reconstruction)
        XCTAssertEqual(loaded.stageTimings, stageTimings)
        XCTAssertNil(loaded.autoTune)
        XCTAssertNil(loaded.shareMetrics)
        XCTAssertEqual(loaded.completedSfmMapping?.mapper, "global_mapper-gpu")
        XCTAssertEqual(loaded.recoveryPromptSuppressed, false)
        XCTAssertEqual(loaded.state.stage, .done)
        XCTAssertEqual(loaded.preset.mode, .room)
        XCTAssertEqual(loaded.preset.quality, .ultra)
        XCTAssertEqual(loaded.input.videoFiles, ["/tmp/a.mov"])
        XCTAssertEqual(loaded.input.photosFolder, "/tmp/photos")
        XCTAssertEqual(loaded.notes, "captured under window light")
        XCTAssertNil(loaded.lastOpenedAt)
        XCTAssertEqual(loaded.lastFailureAt, Date(timeIntervalSince1970: 1_699_999_500))
    }
}

final class ReconstructionSummaryTests: XCTestCase {
    func testRegisteredFractionGuardsAgainstZeroTotal() {
        let summary = ReconstructionSummary(
            mapper: "vggt",
            capturedAt: Date(timeIntervalSince1970: 0),
            registeredImages: 10,
            totalImages: 0
        )
        XCTAssertEqual(summary.registeredFraction, 0)
    }

    func testInitFromReconstructionScoreCarriesAllFields() {
        let score = ReconstructionScore(
            registeredImages: 18,
            totalImages: 20,
            meanReprojectionError: 0.72,
            pointCount: 5_000,
            observationCount: 25_000,
            meanTrackLength: 5.0
        )
        let captured = Date(timeIntervalSince1970: 1_700_000_000)
        let summary = ReconstructionSummary(score: score, mapper: "colmap", capturedAt: captured)

        XCTAssertEqual(summary.mapper, "colmap")
        XCTAssertEqual(summary.capturedAt, captured)
        XCTAssertEqual(summary.registeredImages, 18)
        XCTAssertEqual(summary.totalImages, 20)
        XCTAssertEqual(summary.meanReprojectionError, 0.72)
        XCTAssertEqual(summary.pointCount, 5_000)
        XCTAssertEqual(summary.observationCount, 25_000)
        XCTAssertEqual(summary.meanTrackLength, 5.0)
    }
}
