import XCTest
@testable import EasySplatCore

final class ProjectMetadataStoreTests: XCTestCase {
    func testRoundTripMetadata() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")

        let state = PipelineState(stage: .sfmMatching, lastError: "boom")
        let output = OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
        let checkpoint = PipelineCheckpoint(
            stage: .trainSplat,
            updatedAt: Date(timeIntervalSince1970: 123460),
            progressFraction: 0.5,
            message: "heartbeat",
            details: .trainSplat(TrainSplatCheckpoint(progressStep: 1_200, progressTotal: 40_000))
        )
        let metadata = ProjectMetadata(
            formatVersion: ProjectMetadataStore.supportedFormatVersion,
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 123456),
            title: "Test",
            input: .mixed(videos: ["/tmp/a.mov"], photosFolder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .walkthrough, detailProfile: .highDetail),
            state: state,
            outputs: output,
            checkpoint: checkpoint,
            lastRunStartedAt: Date(timeIntervalSince1970: 123499)
        )

        try ProjectMetadataStore.save(metadata, to: url)
        let loaded = try ProjectMetadataStore.load(from: url)

        XCTAssertEqual(loaded.formatVersion, metadata.formatVersion)
        XCTAssertEqual(loaded.id, metadata.id)
        XCTAssertEqual(loaded.createdAt, metadata.createdAt)
        XCTAssertEqual(loaded.title, metadata.title)
        XCTAssertEqual(loaded.requestedRunOptions, metadata.requestedRunOptions)
        XCTAssertEqual(loaded.state.stage, metadata.state.stage)
        XCTAssertEqual(loaded.state.lastError, metadata.state.lastError)
        XCTAssertEqual(loaded.outputs?.splatPlyPath, metadata.outputs?.splatPlyPath)
        XCTAssertEqual(loaded.outputs?.colmapModelPath, metadata.outputs?.colmapModelPath)
        XCTAssertEqual(loaded.checkpoint?.stage, metadata.checkpoint?.stage)
        XCTAssertEqual(loaded.checkpoint?.message, metadata.checkpoint?.message)
        XCTAssertEqual(loaded.lastRunStartedAt, Date(timeIntervalSince1970: 123499))
        if case let .trainSplat(details)? = loaded.checkpoint?.details {
            XCTAssertEqual(details.progressStep, 1_200)
            XCTAssertEqual(details.progressTotal, 40_000)
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
          "requestedRunOptions":{"capturePath":"automatic","detailProfile":"balanced"},
          "state":{"lastError":null,"stage":"importInput"},
          "title":"Future"
        }
        """
        try future.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ProjectMetadataStore.load(from: url)) { error in
            guard case ProjectMetadataStore.LoadError.requiresNewerApp(let v) = error else {
                XCTFail("Expected requiresNewerApp, got \(error)")
                return
            }
            XCTAssertEqual(v, ProjectMetadataStore.supportedFormatVersion + 1)
            XCTAssertTrue(error.localizedDescription.contains("Update EasySplat"))
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
            guard case ProjectMetadataStore.LoadError.requiresNewerApp(let v) = error else {
                XCTFail("Expected requiresNewerApp even with missing fields, got \(error)")
                return
            }
            XCTAssertEqual(v, ProjectMetadataStore.supportedFormatVersion + 1)
        }
    }

    func testSaveRejectsNonCurrentFormatVersion() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let metadata = ProjectMetadata(
            formatVersion: ProjectMetadataStore.supportedFormatVersion - 1,
            title: "Wrong schema",
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )

        XCTAssertThrowsError(try ProjectMetadataStore.save(metadata, to: url)) { error in
            guard case ProjectMetadataStore.SaveError.invalidFormatVersion(let version) = error else {
                return XCTFail("Expected invalidFormatVersion, got \(error)")
            }
            XCTAssertEqual(version, ProjectMetadataStore.supportedFormatVersion - 1)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testLoadRejectsTrainingArtifactMissingCurrentResumeBinding() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let incompleteVersionTwo = """
        {
          "createdAt":"1970-01-01T00:00:00Z",
          "formatVersion":2,
          "id":"00000000-0000-0000-0000-000000000003",
          "input":{"photos":{"folder":"/tmp/photos"}},
          "outputs":{"colmapModelPath":"SfM/colmap/sparse/0","splatPlyPath":"Output/splat.ply"},
          "requestedRunOptions":{
            "cameraGrouping":"automatic",
            "capturePath":"orbit",
            "detailProfile":"balanced",
            "inputOrdering":"automatic",
            "lensProjection":"automatic",
            "photoSelection":"automatic",
            "resourcePolicy":"automatic"
          },
          "state":{"lastError":null,"stage":"done"},
          "title":"Incomplete v2",
          "trainingArtifact":{
            "completionStatus":"completed",
            "completedIteration":7000,
            "detailProfile":"balanced",
            "deterministicSeed":42,
            "elapsedSeconds":12.5,
            "gaussianCount":1250,
            "geometryDigest":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            "iterationLimit":7000,
            "inputDigest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "outputPath":"Training/msplat/splat.ply",
            "peakMemoryBytes":2147483648,
            "plateauWindow":800,
            "runtimeVersion":"native-metal-cli-v1",
            "schemaVersion":1,
            "trainerVersion":"1.1.3 (git 106499b)"
          }
        }
        """
        try incompleteVersionTwo.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try ProjectMetadataStore.load(from: url)) { error in
            guard case DecodingError.keyNotFound(let key, _) = error else {
                return XCTFail("Expected keyNotFound, got \(error)")
            }
            XCTAssertEqual(key.stringValue, "trainerBuildDigest")
        }
    }

    func testMetadataReadsAndNoteUpdatesDoNotOpenCompletedTrainingOutput() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let missingOutput = "Training/msplat/splat.ply"
        let artifact = TrainingArtifact(
            trainerVersion: "1.1.3",
            runtimeVersion: "native-metal-cli-v1",
            trainerBuildDigest: String(repeating: "a", count: 64),
            inputDigest: String(repeating: "b", count: 64),
            geometryDigest: String(repeating: "c", count: 64),
            detailProfile: .balanced,
            iterationLimit: 7_000,
            plateauWindow: 800,
            deterministicSeed: 42,
            completedIteration: 7_000,
            checkpointPath: nil,
            checkpointDigest: nil,
            outputPath: missingOutput,
            outputSHA256: String(repeating: "d", count: 64),
            outputBytes: 1_024,
            gaussianCount: 100,
            elapsedSeconds: 10,
            peakMemoryBytes: 1_024,
            completionStatus: .completed
        )
        let metadata = ProjectMetadata(
            title: "Missing output",
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(detailProfile: .balanced),
            trainingArtifact: artifact,
            state: PipelineState(stage: .done, lastError: nil),
            outputs: OutputSpec(
                splatPlyPath: "Output/splat.ply",
                colmapModelPath: "SfM/colmap/sparse/0"
            )
        )

        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        XCTAssertEqual(try ProjectMetadataStore.load(from: paths.metadataURL).trainingArtifact, artifact)
        let updated = try ProjectMetadataStore.update(at: paths.metadataURL) { metadata in
            metadata.notes = "Keep this project visible"
        }

        XCTAssertEqual(updated.notes, "Keep this project visible")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: try paths.resolveProjectRelativePath(missingOutput).path
        ))
    }

    func testRoundTripPreservesNotes() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let metadata = ProjectMetadata(
            title: "With Notes",
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
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
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            state: PipelineState(stage: .importInput, lastError: nil),
            notes: nil
        )
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Client-facing name",
                input: .photos(folder: "/tmp/photos"),
                requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
                notes: "newer note from user"
            ),
            to: url
        )

        var stalePipelineWrite = pipelineSnapshot
        stalePipelineWrite.state = PipelineState(stage: .sfmFeatures, lastError: nil)
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
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
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
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
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
                requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
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
                    requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
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
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            state: PipelineState(stage: .importInput, lastError: nil),
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
            lastError: nil
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
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
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
                requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
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
            mapper: "da3-refined",
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
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
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
    func testRoundTripPreservesCurrentFieldsAndOmitsRetiredKeys() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")

        let reconstruction = ReconstructionSummary(
            mapper: "point_triangulator+bundle_adjuster",
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
        let metadata = ProjectMetadata(
            formatVersion: ProjectMetadataStore.supportedFormatVersion,
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            createdAt: Date(timeIntervalSince1970: 1_699_999_000),
            title: "Full schema",
            input: .mixed(videos: ["/tmp/a.mov"], photosFolder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .walkthrough, detailProfile: .highDetail),
            state: PipelineState(stage: .done, lastError: nil),
            outputs: OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0"),
            checkpoint: nil,
            lastRunStartedAt: nil,
            reconstruction: reconstruction,
            stageTimings: stageTimings,
            notes: "captured under window light",
            lastFailureAt: Date(timeIntervalSince1970: 1_699_999_500)
        )

        try ProjectMetadataStore.save(metadata, to: url)
        let loaded = try ProjectMetadataStore.load(from: url)

        XCTAssertEqual(loaded.reconstruction, reconstruction)
        XCTAssertEqual(loaded.stageTimings, stageTimings)
        XCTAssertEqual(loaded.state.stage, .done)
        XCTAssertEqual(loaded.requestedRunOptions.capturePath, .walkthrough)
        XCTAssertEqual(loaded.requestedRunOptions.detailProfile, .highDetail)
        XCTAssertEqual(loaded.input.videoFiles, ["/tmp/a.mov"])
        XCTAssertEqual(loaded.input.photosFolder, "/tmp/photos")
        XCTAssertEqual(loaded.notes, "captured under window light")
        XCTAssertEqual(loaded.lastFailureAt, Date(timeIntervalSince1970: 1_699_999_500))
    }
}

final class ReconstructionSummaryTests: XCTestCase {
    func testRegisteredFractionGuardsAgainstZeroTotal() {
        let summary = ReconstructionSummary(
            mapper: "colmap",
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
