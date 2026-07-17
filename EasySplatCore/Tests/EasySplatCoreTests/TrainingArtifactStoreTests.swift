import XCTest
@testable import EasySplatCore

final class TrainingArtifactStoreTests: XCTestCase {
    func testStoreAcceptsCanonicalPathThroughPrivateTemporaryAlias() throws {
        let root = URL(
            fileURLWithPath: "/private/tmp/EasySplat-TrainingArtifact-\(UUID().uuidString).easysplatproj",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let artifact = makeCheckpointedArtifact()

        try TrainingArtifactStore.save(
            artifact,
            to: paths.trainingManifestURL,
            projectPaths: paths
        )

        XCTAssertEqual(
            try TrainingArtifactStore.load(
                from: paths.trainingManifestURL,
                projectPaths: paths
            ),
            artifact
        )
    }

    func testStoreRejectsExternalAliasToCanonicalManifestAndSymlinkedRoot() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let artifact = makeCheckpointedArtifact()
        try TrainingArtifactStore.save(
            artifact,
            to: context.paths.trainingManifestURL,
            projectPaths: context.paths
        )
        let externalAlias = context.root.deletingLastPathComponent()
            .appendingPathComponent("training-manifest-alias-\(UUID().uuidString).json")
        try FileManager.default.createSymbolicLink(
            at: externalAlias,
            withDestinationURL: context.paths.trainingManifestURL
        )

        XCTAssertThrowsError(try TrainingArtifactStore.save(
            artifact,
            to: externalAlias,
            projectPaths: context.paths
        ))
        XCTAssertNotNil(
            try? FileManager.default.destinationOfSymbolicLink(atPath: externalAlias.path)
        )

        let actualRoot = context.root.deletingLastPathComponent()
            .appendingPathComponent("outside-root-\(UUID().uuidString)", isDirectory: true)
        let symlinkRoot = context.root.deletingLastPathComponent()
            .appendingPathComponent("linked-project-\(UUID().uuidString).easysplatproj")
        defer {
            try? FileManager.default.removeItem(at: symlinkRoot)
            try? FileManager.default.removeItem(at: actualRoot)
        }
        try FileManager.default.createDirectory(
            at: actualRoot.appendingPathComponent("Training", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: symlinkRoot,
            withDestinationURL: actualRoot
        )
        let linkedPaths = ProjectPaths(root: symlinkRoot)

        XCTAssertThrowsError(try TrainingArtifactStore.save(
            artifact,
            to: linkedPaths.trainingManifestURL,
            projectPaths: linkedPaths
        ))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: actualRoot.appendingPathComponent("Training/training_manifest.json").path
            )
        )
    }

    func testCheckpointedArtifactPersistsAndRepairsStaleProjectMetadata() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let artifact = makeCheckpointedArtifact()
        var metadata = context.metadata

        try TrainingArtifactStore.persist(artifact, metadata: &metadata, paths: context.paths)

        XCTAssertEqual(metadata.trainingArtifact, artifact)
        XCTAssertEqual(
            try TrainingArtifactStore.load(
                from: context.paths.trainingManifestURL,
                projectPaths: context.paths
            ),
            artifact
        )

        metadata.trainingArtifact = nil
        try ProjectMetadataStore.save(metadata, to: context.paths.metadataURL)
        var staleMetadata = try ProjectMetadataStore.load(from: context.paths.metadataURL)

        XCTAssertTrue(try TrainingArtifactStore.reconcile(metadata: &staleMetadata, paths: context.paths))
        XCTAssertEqual(staleMetadata.trainingArtifact, artifact)
        XCTAssertEqual(
            try ProjectMetadataStore.load(from: context.paths.metadataURL).trainingArtifact,
            artifact
        )
    }

    func testCompletedArtifactRequiresOutputWithoutCheckpointFields() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let completed = try makeCompletedArtifact(in: context)

        try TrainingArtifactStore.save(
            completed,
            to: context.paths.trainingManifestURL,
            projectPaths: context.paths
        )
        XCTAssertEqual(
            try TrainingArtifactStore.load(
                from: context.paths.trainingManifestURL,
                projectPaths: context.paths
            ),
            completed
        )

        var invalid = completed
        invalid.checkpointPath = "Training/checkpoints/msplat"
        invalid.checkpointDigest = String(repeating: "d", count: 64)
        XCTAssertThrowsError(
            try TrainingArtifactStore.save(
                invalid,
                to: context.paths.trainingManifestURL,
                projectPaths: context.paths
            )
        )
    }

    func testCompletedArtifactRequiresZeroDroppedRasterIntersections() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        var artifact = try makeCompletedArtifact(in: context)
        artifact.droppedIntersectionCount = 1

        XCTAssertThrowsError(
            try TrainingArtifactStore.save(
                artifact,
                to: context.paths.trainingManifestURL,
                projectPaths: context.paths
            )
        )
    }

    func testCompletedArtifactRequiresFinitePositiveSceneBounds() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let completed = try makeCompletedArtifact(in: context)

        var missing = completed
        missing.sceneBounds = nil
        XCTAssertThrowsError(
            try TrainingArtifactStore.save(
                missing,
                to: context.paths.trainingManifestURL,
                projectPaths: context.paths
            )
        )

        let invalidBounds = [
            SplatSceneBounds(center: .init(x: .nan, y: 0, z: 0), radius: 1),
            SplatSceneBounds(center: .init(x: 0, y: .infinity, z: 0), radius: 1),
            SplatSceneBounds(center: .init(x: 0, y: 0, z: 0), radius: 0),
            SplatSceneBounds(center: .init(x: 0, y: 0, z: 0), radius: .infinity),
        ]
        for bounds in invalidBounds {
            var invalid = completed
            invalid.sceneBounds = bounds
            XCTAssertThrowsError(
                try TrainingArtifactStore.save(
                    invalid,
                    to: context.paths.trainingManifestURL,
                    projectPaths: context.paths
                )
            )
        }
    }

    func testCheckpointedArtifactCannotClaimFinalSceneBounds() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        var artifact = makeCheckpointedArtifact()
        artifact.sceneBounds = SplatSceneBounds(
            center: .init(x: 1, y: 2, z: 3),
            radius: 4
        )

        XCTAssertThrowsError(
            try TrainingArtifactStore.save(
                artifact,
                to: context.paths.trainingManifestURL,
                projectPaths: context.paths
            )
        )
    }

    func testCheckpointedArtifactCannotClaimElapsedTrainingTime() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        var artifact = makeCheckpointedArtifact()
        artifact.elapsedSeconds = 0.1

        XCTAssertThrowsError(
            try TrainingArtifactStore.save(
                artifact,
                to: context.paths.trainingManifestURL,
                projectPaths: context.paths
            )
        )
    }

    func testArtifactRejectsFallbackCountsOutsideCompletedIterationsAndNativeRange() throws {
        let context = try makeContext()
        defer { context.cleanup() }

        for invalidCount in [501, Int(UInt32.max) + 1] {
            var artifact = makeCheckpointedArtifact()
            artifact.rasterFallbackCount = invalidCount

            XCTAssertThrowsError(
                try TrainingArtifactStore.save(
                    artifact,
                    to: context.paths.trainingManifestURL,
                    projectPaths: context.paths
                ),
                "Accepted raster fallback count \(invalidCount) at iteration \(artifact.completedIteration)"
            )
        }
    }

    func testArtifactRequiresConsistentRasterRecoveryMetrics() throws {
        let context = try makeContext()
        defer { context.cleanup() }

        var valid = try makeCompletedArtifact(in: context)
        valid.rasterFallbackCount = 3
        valid.rasterExactFallbackElapsedSeconds = 0.25
        valid.rasterExactBufferGrowthCount = 1
        valid.rasterExactBufferBytesAdded = 65_536
        valid.rasterReplayElapsedSeconds = 0.5
        valid.rasterPeakExactIntersectionCapacity = 4_096
        try TrainingArtifactStore.save(
            valid,
            to: context.paths.trainingManifestURL,
            projectPaths: context.paths
        )

        var invalid = valid
        invalid.rasterExactBufferGrowthCount = 4
        XCTAssertThrowsError(try TrainingArtifactStore.save(
            invalid,
            to: context.paths.trainingManifestURL,
            projectPaths: context.paths
        ))

        invalid = valid
        invalid.rasterExactBufferBytesAdded = 0
        XCTAssertThrowsError(try TrainingArtifactStore.save(
            invalid,
            to: context.paths.trainingManifestURL,
            projectPaths: context.paths
        ))

        invalid = valid
        invalid.rasterExactFallbackElapsedSeconds = .infinity
        XCTAssertThrowsError(try TrainingArtifactStore.save(
            invalid,
            to: context.paths.trainingManifestURL,
            projectPaths: context.paths
        ))

        invalid = valid
        invalid.rasterExactFallbackElapsedSeconds = 0
        XCTAssertThrowsError(try TrainingArtifactStore.save(
            invalid,
            to: context.paths.trainingManifestURL,
            projectPaths: context.paths
        ))

        invalid = valid
        invalid.rasterReplayElapsedSeconds = 0
        XCTAssertThrowsError(try TrainingArtifactStore.save(
            invalid,
            to: context.paths.trainingManifestURL,
            projectPaths: context.paths
        ))

        invalid = valid
        invalid.rasterExactBufferGrowthCount = 0
        invalid.rasterExactBufferBytesAdded = 0
        invalid.rasterPeakExactIntersectionCapacity = 0
        XCTAssertThrowsError(try TrainingArtifactStore.save(
            invalid,
            to: context.paths.trainingManifestURL,
            projectPaths: context.paths
        ))

        invalid = valid
        invalid.rasterReplayElapsedSeconds = try XCTUnwrap(valid.elapsedSeconds) + 1
        XCTAssertThrowsError(try TrainingArtifactStore.save(
            invalid,
            to: context.paths.trainingManifestURL,
            projectPaths: context.paths
        ))

        invalid = valid
        invalid.rasterPeakExactIntersectionCapacity = Int64(UInt32.max) + 1
        XCTAssertThrowsError(try TrainingArtifactStore.save(
            invalid,
            to: context.paths.trainingManifestURL,
            projectPaths: context.paths
        ))

        invalid = valid
        invalid.rasterExactBufferBytesAdded = invalid.memoryBudgetBytes + 1
        XCTAssertThrowsError(try TrainingArtifactStore.save(
            invalid,
            to: context.paths.trainingManifestURL,
            projectPaths: context.paths
        ))

        var cumulative = valid
        cumulative.rasterExactBufferGrowthCount = 2
        cumulative.rasterExactBufferBytesAdded = cumulative.memoryBudgetBytes + 1
        try TrainingArtifactStore.save(
            cumulative,
            to: context.paths.trainingManifestURL,
            projectPaths: context.paths
        )
    }

    func testPriorTrainingSchemasAreRejected() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        var artifact = makeCheckpointedArtifact()
        for schema in [1, 2, 3] {
            artifact.schemaVersion = schema
            XCTAssertThrowsError(
                try TrainingArtifactStore.save(
                    artifact,
                    to: context.paths.trainingManifestURL,
                    projectPaths: context.paths
                )
            )
        }
    }

    func testCurrentManifestRequiresEveryRasterRecoveryField() throws {
        let fields = [
            "rasterExactFallbackElapsedSeconds",
            "rasterExactBufferGrowthCount",
            "rasterExactBufferBytesAdded",
            "rasterReplayElapsedSeconds",
            "rasterPeakExactIntersectionCapacity",
        ]
        for field in fields {
            let context = try makeContext()
            defer { context.cleanup() }
            let artifact = try makeCompletedArtifact(in: context)
            try TrainingArtifactStore.save(
                artifact,
                to: context.paths.trainingManifestURL,
                projectPaths: context.paths
            )
            let data = try Data(contentsOf: context.paths.trainingManifestURL)
            var payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            payload.removeValue(forKey: field)
            try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                .write(to: context.paths.trainingManifestURL, options: .atomic)

            XCTAssertThrowsError(
                try TrainingArtifactStore.load(
                    from: context.paths.trainingManifestURL,
                    projectPaths: context.paths
                ),
                "Decoded schema-4 manifest without required field \(field)"
            )
        }
    }

    func testSaveRequiresMeasuredPeakMemoryForNewArtifacts() throws {
        let context = try makeContext()
        defer { context.cleanup() }

        for prototype in [makeCheckpointedArtifact(), try makeCompletedArtifact(in: context)] {
            var artifact = prototype
            artifact.peakMemoryBytes = 0
            XCTAssertThrowsError(
                try TrainingArtifactStore.save(
                    artifact,
                    to: context.paths.trainingManifestURL,
                    projectPaths: context.paths
                )
            )
            var metadata = context.metadata
            XCTAssertThrowsError(
                try TrainingArtifactStore.persist(
                    artifact,
                    metadata: &metadata,
                    paths: context.paths
                )
            )
        }
    }

    func testLoadRejectsArtifactWithoutPeakMemory() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let encoder = JSONEncoder()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(makeCheckpointedArtifact()))
                as? [String: Any]
        )
        object.removeValue(forKey: "peakMemoryBytes")
        try JSONSerialization.data(withJSONObject: object)
            .write(to: context.paths.trainingManifestURL)

        XCTAssertThrowsError(
            try TrainingArtifactStore.load(
                from: context.paths.trainingManifestURL,
                projectPaths: context.paths
            )
        )
    }

    func testProjectMetadataRejectsInvalidEmbeddedTrainingArtifact() throws {
        let context = try makeContext()
        defer { context.cleanup() }

        var invalidSchema = makeCheckpointedArtifact()
        invalidSchema.schemaVersion = 99
        var metadata = context.metadata
        metadata.trainingArtifact = invalidSchema
        XCTAssertThrowsError(
            try ProjectMetadataStore.save(metadata, to: context.paths.metadataURL)
        )

        var mismatchedProfile = makeCheckpointedArtifact()
        mismatchedProfile.detailProfile = .highDetail
        mismatchedProfile.iterationLimit = 15_000
        mismatchedProfile.plateauWindow = 1_500
        metadata.trainingArtifact = mismatchedProfile
        XCTAssertThrowsError(
            try ProjectMetadataStore.save(metadata, to: context.paths.metadataURL)
        )
    }

    func testCompletedArtifactBindsPromotedPublicPlyBytes() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let artifact = try makeCompletedArtifact(in: context)
        var metadata = context.metadata
        try TrainingArtifactStore.persist(artifact, metadata: &metadata, paths: context.paths)

        let publicOutput = context.paths.outputURL.appendingPathComponent("splat.ply")
        try FileManager.default.copyItem(at: context.paths.msplatOutputURL, to: publicOutput)
        var promotedArtifact = artifact
        promotedArtifact.outputPath = "Output/splat.ply"
        try TrainingArtifactStore.persist(
            promotedArtifact,
            metadata: &metadata,
            paths: context.paths
        )
        metadata.outputs = OutputSpec(
            splatPlyPath: "Output/splat.ply",
            colmapModelPath: "SfM/colmap/sparse/0"
        )
        try ProjectMetadataStore.save(metadata, to: context.paths.metadataURL)

        let original = try String(contentsOf: publicOutput, encoding: .utf8)
        let replaced = original.replacingOccurrences(
            of: "0 0 0 1 1 1",
            with: "1 0 0 1 1 1"
        )
        XCTAssertEqual(replaced.utf8.count, original.utf8.count)
        try replaced.write(to: publicOutput, atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: publicOutput), .valid)

        let loaded = try ProjectMetadataStore.load(from: context.paths.metadataURL)
        let loadedArtifact = try XCTUnwrap(loaded.trainingArtifact)
        XCTAssertThrowsError(
            try TrainingArtifactStore.validateCompletedOutput(
                loadedArtifact,
                at: publicOutput
            )
        )
    }

    func testCompletionForDifferentDatasetPreservesPriorArtifactAndPublicOutput() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        var metadata = context.metadata
        var priorArtifact = try makeCompletedArtifact(in: context)
        let publicOutput = context.paths.outputURL.appendingPathComponent("splat.ply")
        try FileManager.default.copyItem(at: context.paths.msplatOutputURL, to: publicOutput)
        priorArtifact.outputPath = "Output/splat.ply"
        try TrainingArtifactStore.persist(
            priorArtifact,
            metadata: &metadata,
            paths: context.paths
        )
        let priorPublicBytes = try Data(contentsOf: publicOutput)

        try TestFileBuilder.writeMinimalPly(
            at: context.paths.msplatOutputURL,
            vertexCount: 2
        )
        let requestedOptions = RequestedRunOptions(
            capturePath: .orbit,
            detailProfile: .balanced
        )
        let plan = RunPlanResolver.resolve(
            requestedOptions: requestedOptions,
            input: metadata.input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        let datasetIdentity = MsplatDatasetIdentity(
            inputDigest: String(repeating: "b", count: 64),
            geometryDigest: String(repeating: "c", count: 64)
        )
        let outputBytes = Int64(
            try XCTUnwrap(
                context.paths.msplatOutputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            )
        )
        let mismatchedIdentities = [
            (String(repeating: "f", count: 64), datasetIdentity.geometryDigest),
            (datasetIdentity.inputDigest, String(repeating: "f", count: 64)),
        ]
        let runner = PipelineRunner(
            projectURL: context.root,
            config: .init(toolchain: TestToolchains.toolchainPaths(root: context.root))
        )

        for (inputDigest, geometryDigest) in mismatchedIdentities {
            let result = MsplatTrainingResult(
                profile: .balanced,
                iterationLimit: plan.trainerIterationLimit,
                plateauWindow: plan.plateauWindow,
                completedIteration: plan.trainerIterationLimit,
                stopReason: .iterationLimit,
                gaussianCount: 2,
                elapsedSeconds: 2,
                peakMemoryBytes: 2_147_483_648,
                memoryBudgetBytes: plan.trainerMemoryBudgetBytes,
                rasterFallbackCount: 0,
                rasterExactFallbackElapsedSeconds: 0,
                rasterExactBufferGrowthCount: 0,
                rasterExactBufferBytesAdded: 0,
                rasterReplayElapsedSeconds: 0,
                rasterPeakExactIntersectionCapacity: 0,
                droppedIntersectionCount: 0,
                sceneBounds: SplatSceneBounds(
                    center: .init(x: 0, y: 0, z: 0),
                    radius: 2
                ),
                outputBytes: outputBytes,
                inputDigest: inputDigest,
                geometryDigest: geometryDigest,
                trainerBuildDigest: String(repeating: "a", count: 64),
                latestCheckpoint: nil
            )

            XCTAssertThrowsError(
                try runner.persistMsplatCompletion(
                    result,
                    profile: .balanced,
                    cameraOrderSeed: plan.runSeed,
                    resolvedPlan: plan,
                    datasetIdentity: datasetIdentity,
                    paths: context.paths
                )
            )
            XCTAssertEqual(
                try ProjectMetadataStore.load(from: context.paths.metadataURL).trainingArtifact,
                priorArtifact
            )
            XCTAssertEqual(
                try TrainingArtifactStore.load(
                    from: context.paths.trainingManifestURL,
                    projectPaths: context.paths
                ),
                priorArtifact
            )
            XCTAssertEqual(try Data(contentsOf: publicOutput), priorPublicBytes)
        }
    }

    func testCheckpointedArtifactRequiresExactCheckpointNamespaceAndNoOutput() throws {
        let context = try makeContext()
        defer { context.cleanup() }

        var invalidPath = makeCheckpointedArtifact()
        invalidPath.checkpointPath = "Training/checkpoints/msplat/older"
        XCTAssertThrowsError(
            try TrainingArtifactStore.save(
                invalidPath,
                to: context.paths.trainingManifestURL,
                projectPaths: context.paths
            )
        )

        var invalidOutput = makeCheckpointedArtifact()
        invalidOutput.outputPath = "Output/splat.ply"
        XCTAssertThrowsError(
            try TrainingArtifactStore.save(
                invalidOutput,
                to: context.paths.trainingManifestURL,
                projectPaths: context.paths
            )
        )
    }

    func testDiscardRemovesOnlyCheckpointedResumeRecord() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        var metadata = context.metadata
        try TrainingArtifactStore.persist(
            makeCheckpointedArtifact(),
            metadata: &metadata,
            paths: context.paths
        )

        try TrainingArtifactStore.discardCheckpointedArtifact(
            metadata: &metadata,
            paths: context.paths
        )

        XCTAssertNil(metadata.trainingArtifact)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.paths.trainingManifestURL.path))
        XCTAssertNil(try ProjectMetadataStore.load(from: context.paths.metadataURL).trainingArtifact)
    }

    func testLoadRejectsOversizedAndEscapingManifestFiles() throws {
        let context = try makeContext()
        defer { context.cleanup() }

        try Data(repeating: 0x20, count: 1_048_577).write(to: context.paths.trainingManifestURL)
        XCTAssertThrowsError(
            try TrainingArtifactStore.load(
                from: context.paths.trainingManifestURL,
                projectPaths: context.paths
            )
        )

        try FileManager.default.removeItem(at: context.paths.trainingURL)
        let outside = context.root.deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: context.paths.trainingURL,
            withDestinationURL: outside
        )
        try JSONEncoder().encode(makeCheckpointedArtifact())
            .write(to: outside.appendingPathComponent("training_manifest.json"))

        XCTAssertThrowsError(
            try TrainingArtifactStore.load(
                from: context.paths.trainingManifestURL,
                projectPaths: context.paths
            )
        )
    }

    func testDiscardRemovesReservedCheckpointSymlinkWithoutTouchingTarget() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let outside = context.root.deletingLastPathComponent()
            .appendingPathComponent("outside-checkpoint-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        var metadata = context.metadata
        try TrainingArtifactStore.persist(
            makeCheckpointedArtifact(),
            metadata: &metadata,
            paths: context.paths
        )
        // Simulate a project being tampered with after its secured directory layout
        // was created. The production setup now creates this checkpoint directory.
        try FileManager.default.removeItem(at: context.paths.msplatCheckpointURL)
        try FileManager.default.createSymbolicLink(
            at: context.paths.msplatCheckpointURL,
            withDestinationURL: outside
        )

        try TrainingArtifactStore.discardCheckpointedArtifact(
            metadata: &metadata,
            paths: context.paths
        )

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: context.paths.msplatCheckpointURL.path)
        )
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertNil(metadata.trainingArtifact)
    }

    func testDiscardRemovesReservedManifestSymlinkWithoutTouchingTarget() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        var metadata = context.metadata
        try TrainingArtifactStore.persist(
            makeCheckpointedArtifact(),
            metadata: &metadata,
            paths: context.paths
        )
        try FileManager.default.removeItem(at: context.paths.trainingManifestURL)

        let outside = context.root.deletingLastPathComponent()
            .appendingPathComponent("outside-manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outside) }
        let sentinel = Data("keep outside manifest".utf8)
        try sentinel.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: context.paths.trainingManifestURL,
            withDestinationURL: outside
        )

        try TrainingArtifactStore.discardCheckpointedArtifact(
            metadata: &metadata,
            paths: context.paths
        )

        XCTAssertNil(metadata.trainingArtifact)
        XCTAssertNil(
            try? FileManager.default.destinationOfSymbolicLink(
                atPath: context.paths.trainingManifestURL.path
            )
        )
        XCTAssertEqual(try Data(contentsOf: outside), sentinel)
    }

    func testDiscardCompletedArtifactPreservesPublicOutputAndDoesNotFollowTrainingSymlink() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        var metadata = context.metadata
        try TrainingArtifactStore.persist(
            try makeCompletedArtifact(in: context),
            metadata: &metadata,
            paths: context.paths
        )
        let publicOutput = context.paths.outputURL.appendingPathComponent("splat.ply")
        let publicBytes = Data("validated public output".utf8)
        try publicBytes.write(to: publicOutput)

        try FileManager.default.removeItem(at: context.paths.trainingURL)
        let outside = context.root.deletingLastPathComponent()
            .appendingPathComponent("outside-training-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: context.paths.trainingURL,
            withDestinationURL: outside
        )

        try TrainingArtifactStore.discardCompletedArtifact(
            metadata: &metadata,
            paths: context.paths
        )

        XCTAssertNil(metadata.trainingArtifact)
        XCTAssertNil(try ProjectMetadataStore.load(from: context.paths.metadataURL).trainingArtifact)
        XCTAssertNil(
            try? FileManager.default.destinationOfSymbolicLink(
                atPath: context.paths.trainingURL.path
            )
        )
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: publicOutput), publicBytes)
    }

    private func makeContext() throws -> ArtifactStoreTestContext {
        let root = try TestFileBuilder.makeTempDir()
            .appendingPathComponent("Artifact.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let metadata = ProjectMetadata(
            title: "Artifact",
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .orbit, detailProfile: .balanced)
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        return ArtifactStoreTestContext(root: root, paths: paths, metadata: metadata)
    }

    private func makeCheckpointedArtifact() -> TrainingArtifact {
        TrainingArtifact(
            trainerVersion: "1.1.3 (git 106499b)",
            runtimeVersion: "native-metal-cli-v2",
            trainerBuildDigest: String(repeating: "a", count: 64),
            inputDigest: String(repeating: "b", count: 64),
            geometryDigest: String(repeating: "c", count: 64),
            detailProfile: .balanced,
            iterationLimit: 7_000,
            plateauWindow: 800,
            cameraOrderSeed: 42,
            completedIteration: 500,
            checkpointPath: "Training/checkpoints/msplat",
            checkpointDigest: String(repeating: "d", count: 64),
            outputPath: nil,
            gaussianCount: 1_250,
            elapsedSeconds: nil,
            peakMemoryBytes: 2_147_483_648,
            memoryBudgetBytes: 8_589_934_592,
            rasterFallbackCount: 0,
            rasterExactFallbackElapsedSeconds: 0,
            rasterExactBufferGrowthCount: 0,
            rasterExactBufferBytesAdded: 0,
            rasterReplayElapsedSeconds: 0,
            rasterPeakExactIntersectionCapacity: 0,
            droppedIntersectionCount: 0,
            completionStatus: .checkpointed
        )
    }

    private func makeCompletedArtifact(in context: ArtifactStoreTestContext) throws -> TrainingArtifact {
        try TestFileBuilder.writeMinimalPly(at: context.paths.msplatOutputURL)
        var artifact = makeCheckpointedArtifact()
        artifact.completedIteration = artifact.iterationLimit
        artifact.checkpointPath = nil
        artifact.checkpointDigest = nil
        artifact.outputPath = "Training/msplat/splat.ply"
        artifact.outputSHA256 = try GeometryArtifactStore.sha256(
            of: context.paths.msplatOutputURL
        )
        artifact.outputBytes = Int64(
            try XCTUnwrap(
                context.paths.msplatOutputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            )
        )
        artifact.gaussianCount = 1
        artifact.elapsedSeconds = 12.5
        artifact.sceneBounds = SplatSceneBounds(
            center: .init(x: 0.25, y: -0.5, z: 1.5),
            radius: 3.75
        )
        artifact.completionStatus = .completed
        return artifact
    }
}

private struct ArtifactStoreTestContext {
    let root: URL
    let paths: ProjectPaths
    let metadata: ProjectMetadata

    func cleanup() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}
