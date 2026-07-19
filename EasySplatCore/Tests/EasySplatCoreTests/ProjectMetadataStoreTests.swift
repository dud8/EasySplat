import XCTest
@testable import EasySplatCore

final class ProjectMetadataStoreTests: XCTestCase {
    func testSaveAndLoadRejectInvalidResolvedRunPlanWithoutGeometry() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        for invalidWorkerCount in [0, 65] {
            let url = root.appendingPathComponent("project-\(invalidWorkerCount).json")
            var plan = RunPlanResolver.resolve(
                requestedOptions: RequestedRunOptions(),
                input: .video(files: ["/tmp/clip.mov"]),
                hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
                developmentOverrides: .none
            )
            plan.geometryWorkerBudget.coupledMatchingWorkers = invalidWorkerCount
            let metadata = ProjectMetadata(
                title: "Invalid plan",
                input: .video(files: ["/tmp/clip.mov"]),
                resolvedRunPlan: plan
            )

            XCTAssertThrowsError(try ProjectMetadataStore.save(metadata, to: url)) { error in
                guard case ProjectMetadataStore.LoadError.invalidResolvedRunPlan = error else {
                    return XCTFail("Expected invalid resolved plan, got \(error)")
                }
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(metadata).write(to: url, options: .atomic)
            XCTAssertThrowsError(try ProjectMetadataStore.load(from: url)) { error in
                guard case ProjectMetadataStore.LoadError.invalidResolvedRunPlan = error else {
                    return XCTFail("Expected invalid resolved plan, got \(error)")
                }
            }
        }
    }

    func testCrossClipRetrievalDerivationRoundTripsAndRejectsContradictions() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let hardware = HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36)
        let cases: [(name: String, ordering: InputOrdering, includesPhotos: Bool, expected: Bool)] = [
            ("automatic", .automatic, false, true),
            ("continuous", .continuous, false, true),
            ("unordered", .unordered, false, false),
            ("mixed", .automatic, true, false),
        ]

        for testCase in cases {
            let projectRoot = root.appendingPathComponent(
                "\(testCase.name).easysplatproj",
                isDirectory: true
            )
            let paths = ProjectPaths(root: projectRoot)
            var first = try TestFileBuilder.writeControlledVideoReceipt(
                paths: paths,
                index: 0,
                bytes: Data("first-\(testCase.name)".utf8),
                safeDisplayName: "First.mov"
            )
            var second = try TestFileBuilder.writeControlledVideoReceipt(
                paths: paths,
                index: 1,
                bytes: Data("second-\(testCase.name)".utf8),
                safeDisplayName: "Second.mov"
            )
            let photo = testCase.includesPhotos
                ? try TestFileBuilder.writeControlledPhotoReceipt(paths: paths)
                : nil
            let videoPaths = [
                first.receipt.projectRelativePath,
                second.receipt.projectRelativePath,
            ]
            let input: InputSpec = if testCase.includesPhotos {
                .mixed(videos: videoPaths, photosFolder: "Originals/Photos")
            } else {
                .video(files: videoPaths)
            }
            let options = RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced,
                inputOrdering: testCase.ordering
            )
            let plan = RunPlanResolver.resolve(
                requestedOptions: options,
                input: input,
                hardware: hardware,
                developmentOverrides: .none
            )
            let clipGroupIDs = try Dictionary(uniqueKeysWithValues:
                VideoClipIdentityResolver.resolve(
                    sourceSHA256s: [first.receipt.sha256, second.receipt.sha256],
                    pairingPolicy: plan.pairingPolicy
                ).map { ($0.sourceIndex, $0.groupID) }
            )
            first = try TestFileBuilder.writeControlledVideoReceipt(
                paths: paths,
                index: 0,
                bytes: Data("first-\(testCase.name)".utf8),
                safeDisplayName: "First.mov",
                clipGroupID: try XCTUnwrap(clipGroupIDs[0])
            )
            second = try TestFileBuilder.writeControlledVideoReceipt(
                paths: paths,
                index: 1,
                bytes: Data("second-\(testCase.name)".utf8),
                safeDisplayName: "Second.mov",
                clipGroupID: try XCTUnwrap(clipGroupIDs[1])
            )
            XCTAssertEqual(
                plan.requiresCrossClipRetrieval,
                testCase.expected,
                testCase.name
            )
            let metadata = ProjectMetadata(
                title: "Cross-clip \(testCase.name)",
                input: input,
                videoInputReceipts: [first.receipt, second.receipt],
                photoInputReceipts: photo.map { [$0.receipt] },
                photoSelectionReceipt: photo.map { _ in
                    TestFileBuilder.structuralPhotoSelectionReceipt()
                },
                requestedRunOptions: options,
                resolvedRunPlan: plan
            )

            try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
            XCTAssertEqual(
                try ProjectMetadataStore.load(from: paths.metadataURL)
                    .resolvedRunPlan?.requiresCrossClipRetrieval,
                testCase.expected,
                testCase.name
            )

            var contradictory = metadata
            contradictory.resolvedRunPlan?.requiresCrossClipRetrieval.toggle()
            XCTAssertThrowsError(
                try ProjectMetadataStore.save(contradictory, to: paths.metadataURL),
                testCase.name
            ) { error in
                guard case ProjectMetadataStore.LoadError.invalidResolvedRunPlan = error else {
                    return XCTFail("Expected invalid resolved plan for \(testCase.name), got \(error)")
                }
            }
        }
    }

    func testSaveAndLoadRejectDerivedCrossClipRetrievalRequirementMismatch() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        let first = try TestFileBuilder.writeControlledVideoReceipt(
            paths: paths,
            index: 0,
            bytes: Data("first-video".utf8),
            safeDisplayName: "First.mov"
        )
        let second = try TestFileBuilder.writeControlledVideoReceipt(
            paths: paths,
            index: 1,
            bytes: Data("second-video".utf8),
            safeDisplayName: "Second.mov"
        )
        let input = InputSpec.video(files: [
            first.receipt.projectRelativePath,
            second.receipt.projectRelativePath,
        ])
        let options = RequestedRunOptions(
            capturePath: .orbit,
            detailProfile: .balanced,
            inputOrdering: .continuous
        )
        var plan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        XCTAssertTrue(plan.requiresCrossClipRetrieval)
        plan.requiresCrossClipRetrieval = false
        let metadata = ProjectMetadata(
            title: "Cross-clip geometry binding",
            input: input,
            videoInputReceipts: [first.receipt, second.receipt],
            requestedRunOptions: options,
            resolvedRunPlan: plan
        )

        XCTAssertThrowsError(try ProjectMetadataStore.save(metadata, to: paths.metadataURL)) { error in
            guard case ProjectMetadataStore.LoadError.invalidResolvedRunPlan = error else {
                return XCTFail("Expected derived cross-clip plan mismatch, got \(error)")
            }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: paths.metadataURL, options: .atomic)
        XCTAssertThrowsError(try ProjectMetadataStore.load(from: paths.metadataURL)) { error in
            guard case ProjectMetadataStore.LoadError.invalidResolvedRunPlan = error else {
                return XCTFail("Expected derived cross-clip plan mismatch, got \(error)")
            }
        }
    }

    func testRoundTripValidatesGeometryRecoveryState() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let recovery = GeometryRecoveryState(
            selectedFramesDigest: String(repeating: "a", count: 64),
            orderedImageNames: [
                "frame_000001.jpg",
                "frame_000002.jpg",
                "frame_000003.jpg",
            ],
            activeBackend: .colmap,
            mappingAttemptCount: 1,
            mappingFallbackReasons: ["interrupted mapping resumed"],
            colmapComputeMode: .cpu,
            plannedIncrementalCadence: .balancedGlobal,
            activeIncrementalCadence: .balancedGlobal
        )
        let metadata = ProjectMetadata(
            title: "Recovering geometry",
            input: .video(files: []),
            geometryRecovery: recovery
        )

        try ProjectMetadataStore.save(metadata, to: url)
        XCTAssertEqual(
            try ProjectMetadataStore.load(from: url).geometryRecovery,
            recovery
        )

        var invalid = metadata
        invalid.geometryRecovery?.mappingAttemptCount = -1
        XCTAssertThrowsError(try ProjectMetadataStore.save(invalid, to: url)) { error in
            guard case ProjectMetadataStore.LoadError.invalidGeometryRecovery = error else {
                return XCTFail("Expected invalid geometry recovery, got \(error)")
            }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(invalid).write(to: url, options: .atomic)
        XCTAssertNil(
            try ProjectMetadataStore.load(from: url).geometryRecovery,
            "Disposable recovery corruption must not make the project unreadable."
        )
    }

    func testRoundTripPreservesViewerPreferenceWithoutEmbeddingGeometry() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let metadata = ProjectMetadata(
            title: "Ambiguous upright",
            input: .video(files: []),
            viewerPreferences: ViewerPreferences(isUprightFlipActive: true)
        )

        try ProjectMetadataStore.save(metadata, to: url)
        let loaded = try ProjectMetadataStore.load(from: url)

        XCTAssertTrue(loaded.viewerPreferences.isUprightFlipActive)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertNil(object["geometryArtifact"])
        XCTAssertNil(object["trainingArtifact"])

        let updated = try ProjectMetadataStore.update(at: url) { metadata in
            metadata.notes = "Keep the view flipped"
        }
        XCTAssertTrue(updated.viewerPreferences.isUprightFlipActive)
        XCTAssertTrue(
            try ProjectMetadataStore.load(from: url)
                .viewerPreferences.isUprightFlipActive
        )
    }

    func testRoundTripMetadata() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        let url = paths.metadataURL
        let (_, receipt) = try TestFileBuilder.writeControlledVideoReceipt(paths: paths)

        let state = PipelineState(stage: .sfmMatching, lastError: "boom")
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
            input: .video(files: [receipt.projectRelativePath]),
            videoInputReceipts: [receipt],
            requestedRunOptions: RequestedRunOptions(capturePath: .walkthrough, detailProfile: .highDetail),
            state: state,
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
            guard case ProjectMetadataStore.LoadError.unsupportedFormatVersion(let v) = error else {
                XCTFail("Expected unsupportedFormatVersion, got \(error)")
                return
            }
            XCTAssertEqual(v, ProjectMetadataStore.supportedFormatVersion + 1)
            XCTAssertTrue(
                error.localizedDescription.contains(
                    "opens format \(ProjectMetadataStore.supportedFormatVersion) projects only"
                )
            )
        }
    }

    /// Regression: a future EasySplat may rename or drop fields that today's strict
    /// ProjectMetadata decoder requires. The formatVersion check must fire BEFORE the
    /// strict decode so the library can classify and exclude the incompatible bundle
    /// without partially interpreting a schema it does not understand.
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
                XCTFail("Expected envelope-first unsupportedFormatVersion, got \(error)")
                return
            }
            XCTAssertEqual(v, ProjectMetadataStore.supportedFormatVersion + 1)
        }
    }

    func testLoadRejectsRetiredFormat30FieldsAndMappingCheckpointPayload() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let metadata = ProjectMetadata(
            title: "Current only",
            input: .video(files: [])
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let baseline = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(metadata))
                as? [String: Any]
        )

        for (field, value) in [
            (
                "outputs",
                [
                    "splatPlyPath": "Output/splat.ply",
                    "colmapModelPath": "SfM/colmap/sparse/0",
                ] as [String: Any]
            ),
            (
                "reconstruction",
                [
                    "mapper": "colmap",
                    "capturedAt": "2026-07-21T00:00:00Z",
                    "registeredImages": 3,
                    "totalImages": 3,
                ] as [String: Any]
            ),
        ] {
            var payload = baseline
            payload[field] = value
            try JSONSerialization.data(withJSONObject: payload).write(to: url)

            XCTAssertThrowsError(try ProjectMetadataStore.load(from: url)) { error in
                guard case ProjectMetadataStore.LoadError.unexpectedFields = error else {
                    return XCTFail("Expected retired \(field) rejection, got \(error)")
                }
            }
        }

        var mappingPayload = baseline
        mappingPayload["checkpoint"] = [
            "stage": "sfmMapping",
            "updatedAt": "2026-07-21T00:00:00Z",
            "details": [
                "sfmMapping": [
                    "_0": [
                        "mapper": "colmap",
                        "sparsePath": "SfM/colmap/sparse/0",
                        "registeredImages": 3,
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: mappingPayload).write(to: url)

        XCTAssertThrowsError(try ProjectMetadataStore.load(from: url))
    }

    func testSaveRejectsNonCurrentFormatVersion() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let metadata = ProjectMetadata(
            formatVersion: ProjectMetadataStore.supportedFormatVersion - 1,
            title: "Wrong schema",
            input: .video(files: []),
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

    func testSaveRejectsNonpositiveTrainingMemoryRetryBudget() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let metadata = ProjectMetadata(
            title: "Invalid memory retry",
            input: .video(files: []),
            trainingMemoryRetryBudgetBytes: 0
        )

        XCTAssertThrowsError(try ProjectMetadataStore.save(metadata, to: url)) { error in
            guard case ProjectMetadataStore.LoadError.invalidTrainingMemoryRetryBudget(0) = error else {
                return XCTFail("Expected invalidTrainingMemoryRetryBudget, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMetadataReadsAndNoteUpdatesDoNotRequireArtifactSidecars() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let metadata = ProjectMetadata(
            title: "Metadata only",
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(detailProfile: .balanced),
            state: PipelineState(stage: .done, lastError: nil)
        )

        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        XCTAssertNoThrow(try ProjectMetadataStore.load(from: paths.metadataURL))
        let updated = try ProjectMetadataStore.update(at: paths.metadataURL) { metadata in
            metadata.notes = "Keep this project visible"
        }

        XCTAssertEqual(updated.notes, "Keep this project visible")
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.geometryManifestURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.trainingManifestURL.path))
    }

    func testRoundTripPreservesNotes() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let metadata = ProjectMetadata(
            title: "With Notes",
            input: .video(files: []),
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
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced),
            state: PipelineState(stage: .importInput, lastError: nil),
            notes: nil
        )
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Client-facing name",
                input: .video(files: []),
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
            input: .video(files: []),
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
            input: .video(files: []),
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
                input: .video(files: []),
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
                    input: .video(files: []),
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
            input: .video(files: []),
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
                    metadata.viewerPreferences.isUprightFlipActive = true
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
        XCTAssertTrue(loaded.viewerPreferences.isUprightFlipActive)
        XCTAssertEqual(loaded.state.stage, .sfmFeatures)
    }

    func testSaveRejectsMetadataThatWouldExceedLoadLimitAndPreservesCurrentFile() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")
        let initial = ProjectMetadata(
            title: "Readable",
            input: .video(files: []),
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
                input: .video(files: []),
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
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(capturePath: .walkthrough, detailProfile: .highDetail),
            state: PipelineState(stage: .done, lastError: nil),
            checkpoint: nil,
            lastRunStartedAt: nil,
            stageTimings: stageTimings,
            createToViewerReadySeconds: 812.75,
            notes: "captured under window light",
            lastFailureAt: Date(timeIntervalSince1970: 1_699_999_500)
        )

        try ProjectMetadataStore.save(metadata, to: url)
        let loaded = try ProjectMetadataStore.load(from: url)

        XCTAssertEqual(loaded.stageTimings, stageTimings)
        XCTAssertEqual(loaded.createToViewerReadySeconds, 812.75)
        XCTAssertEqual(loaded.state.stage, .done)
        XCTAssertEqual(loaded.requestedRunOptions.capturePath, .walkthrough)
        XCTAssertEqual(loaded.requestedRunOptions.detailProfile, .highDetail)
        XCTAssertEqual(loaded.input.videoFiles, [])
        XCTAssertNil(loaded.input.photosFolder)
        XCTAssertEqual(loaded.notes, "captured under window light")
        XCTAssertEqual(loaded.lastFailureAt, Date(timeIntervalSince1970: 1_699_999_500))
    }
}
