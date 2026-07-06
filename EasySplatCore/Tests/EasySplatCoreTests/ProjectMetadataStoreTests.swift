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
            stage: .trainBrush,
            updatedAt: Date(timeIntervalSince1970: 123460),
            progressFraction: 0.5,
            message: "heartbeat",
            details: .trainBrush(TrainBrushCheckpoint(
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
            formatVersion: 1,
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
        if case let .trainBrush(details)? = loaded.checkpoint?.details {
            XCTAssertEqual(details.latestExportStep, 1000)
            XCTAssertEqual(details.progressTotal, 40_000)
        } else {
            XCTFail("Expected trainBrush checkpoint details")
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

    func testSavePreservingUserEditableFieldsKeepsNewerNotesOnDisk() throws {
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
                title: "Race",
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
        XCTAssertEqual(loaded.notes, "newer note from user")
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

final class ProjectMetadataFullSchemaRoundTripTests: XCTestCase {
    /// Regression guard: any future build that ships an additional optional
    /// metadata field must still round-trip the full set without losing the
    /// older ones. This test exercises every field added since the original
    /// schema so a refactor that accidentally drops a Codable key fails fast.
    func testRoundTripPreservesEveryPersistedField() throws {
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
            .init(stage: .trainBrush, startedAt: Date(timeIntervalSince1970: 1_700_000_400), durationSeconds: 600)
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
            formatVersion: 1,
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
        let loaded = try ProjectMetadataStore.load(from: url)

        XCTAssertEqual(loaded.reconstruction, reconstruction)
        XCTAssertEqual(loaded.stageTimings, stageTimings)
        XCTAssertEqual(loaded.autoTune, autoTune)
        XCTAssertEqual(loaded.shareMetrics, metadata.shareMetrics)
        XCTAssertEqual(loaded.completedSfmMapping?.mapper, "global_mapper-gpu")
        XCTAssertEqual(loaded.recoveryPromptSuppressed, false)
        XCTAssertEqual(loaded.state.stage, .done)
        XCTAssertEqual(loaded.preset.mode, .room)
        XCTAssertEqual(loaded.preset.quality, .ultra)
        XCTAssertEqual(loaded.input.videoFiles, ["/tmp/a.mov"])
        XCTAssertEqual(loaded.input.photosFolder, "/tmp/photos")
        XCTAssertEqual(loaded.notes, "captured under window light")
        XCTAssertEqual(loaded.lastOpenedAt, Date(timeIntervalSince1970: 1_700_001_000))
        XCTAssertEqual(loaded.lastFailureAt, Date(timeIntervalSince1970: 1_699_999_500))
    }
}

final class AutoTuneSnapshotPersistenceTests: XCTestCase {
    func testRoundTripPreservesAutoTuneSnapshot() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")

        let snapshot = AutoTuneSnapshot(
            tier: "Mid",
            memoryGB: 24.0,
            cpuCount: 10,
            gpuWorkingSetGB: 16.0,
            mapAnythingResolution: 518,
            mapAnythingDirectViewLimit: 6,
            mapAnythingAnchorMaxViews: 48,
            mapAnythingWindowSize: 6,
            mapAnythingWindowOverlap: 2,
            vggtImageLoadResolution: 1024,
            vggtFixedResolution: 518,
            vggtMaxPoints: 100_000,
            vggtAllowed: true,
            colmapMaxNumFeatures: 8_192,
            colmapMaxNumMatches: 8_192,
            colmapSequentialOverlap: 10,
            colmapExhaustiveBlockSize: 20,
            threadCap: 6,
            colmapMaxImageSizeCap: nil,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let metadata = ProjectMetadata(
            title: "With Auto-tune",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard),
            autoTune: snapshot
        )
        try ProjectMetadataStore.save(metadata, to: url)
        let loaded = try ProjectMetadataStore.load(from: url)
        XCTAssertEqual(loaded.autoTune, snapshot)
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
        let summary = ReconstructionSummary(score: score, mapper: "mapanything-direct", capturedAt: captured)

        XCTAssertEqual(summary.mapper, "mapanything-direct")
        XCTAssertEqual(summary.capturedAt, captured)
        XCTAssertEqual(summary.registeredImages, 18)
        XCTAssertEqual(summary.totalImages, 20)
        XCTAssertEqual(summary.meanReprojectionError, 0.72)
        XCTAssertEqual(summary.pointCount, 5_000)
        XCTAssertEqual(summary.observationCount, 25_000)
        XCTAssertEqual(summary.meanTrackLength, 5.0)
    }
}
