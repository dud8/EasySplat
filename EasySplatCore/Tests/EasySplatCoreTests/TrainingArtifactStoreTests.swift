import Darwin
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

    func testCheckpointedArtifactPersistsOnlyToSidecar() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let artifact = makeCheckpointedArtifact()
        let metadataBeforePersist = try Data(contentsOf: context.paths.metadataURL)

        try TrainingArtifactStore.persist(artifact, paths: context.paths)

        XCTAssertEqual(
            try TrainingArtifactStore.load(
                from: context.paths.trainingManifestURL,
                projectPaths: context.paths
            ),
            artifact
        )
        XCTAssertEqual(
            try Data(contentsOf: context.paths.metadataURL),
            metadataBeforePersist
        )
        var manifestStatus = stat()
        XCTAssertEqual(lstat(context.paths.trainingManifestURL.path, &manifestStatus), 0)
        XCTAssertEqual(manifestStatus.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(manifestStatus.st_mode & 0o7777, mode_t(0o600))
        XCTAssertEqual(manifestStatus.st_nlink, 1)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: context.paths.trainingURL.path)
                .contains(where: { $0.hasPrefix(".training-manifest.") })
        )
        let metadataObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: metadataBeforePersist) as? [String: Any]
        )
        XCTAssertNil(metadataObject["geometryArtifact"])
        XCTAssertNil(metadataObject["trainingArtifact"])
    }

    func testPersistTrainingSwapAfterEncodingCannotWriteOutsideProject() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let artifact = makeCheckpointedArtifact()
        let originalTraining = context.paths.trainingURL
        let displacedTraining = context.root.deletingLastPathComponent()
            .appendingPathComponent("PersistDisplaced-\(UUID().uuidString)", isDirectory: true)
        let externalTraining = context.root.deletingLastPathComponent()
            .appendingPathComponent("PersistExternal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: externalTraining,
            withIntermediateDirectories: true
        )
        let externalMarker = externalTraining.appendingPathComponent("keep.txt")
        let markerBytes = Data("outside must survive".utf8)
        try markerBytes.write(to: externalMarker)

        XCTAssertThrowsError(try TrainingArtifactStore.persist(
            artifact,
            paths: context.paths,
            operations: TrainingFilesystemOperations { checkpoint in
                guard checkpoint == .manifestDirectoryBound else { return }
                try FileManager.default.moveItem(
                    at: originalTraining,
                    to: displacedTraining
                )
                try FileManager.default.createSymbolicLink(
                    at: originalTraining,
                    withDestinationURL: externalTraining
                )
            }
        ))

        XCTAssertEqual(try Data(contentsOf: externalMarker), markerBytes)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: externalTraining.appendingPathComponent("training_manifest.json").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: displacedTraining.appendingPathComponent("training_manifest.json").path
            )
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

    func testPreparedReboundManifestUsesExactDeterministicBytesAndPersistsOnlyAfterOutput() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let completed = try makeCompletedPublicationArtifact(in: context)
        try TrainingArtifactStore.persist(completed, paths: context.paths)
        var rebound = completed
        rebound.outputPath = "Output/splat.ply"

        let first = try TrainingArtifactStore.encodedManifestData(
            rebound,
            projectPaths: context.paths
        )
        let second = try TrainingArtifactStore.encodedManifestData(
            rebound,
            projectPaths: context.paths
        )
        XCTAssertEqual(first, second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.paths.outputSplatURL.path))
        XCTAssertThrowsError(try TrainingArtifactStore.persistPreparedManifest(
            first,
            artifact: rebound,
            paths: context.paths
        ))

        try FileManager.default.copyItem(
            at: context.paths.msplatOutputURL,
            to: context.paths.outputSplatURL
        )
        try TrainingArtifactStore.persistPreparedManifest(
            first,
            artifact: rebound,
            paths: context.paths
        )
        XCTAssertEqual(try Data(contentsOf: context.paths.trainingManifestURL), first)
        var manifestStatus = stat()
        XCTAssertEqual(lstat(context.paths.trainingManifestURL.path, &manifestStatus), 0)
        XCTAssertEqual(manifestStatus.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(manifestStatus.st_mode & 0o7777, mode_t(0o600))
        XCTAssertEqual(manifestStatus.st_nlink, 1)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: context.paths.trainingURL.path)
                .contains(where: { $0.hasPrefix(".training-manifest.") })
        )
        XCTAssertEqual(
            try TrainingArtifactStore.load(
                from: context.paths.trainingManifestURL,
                projectPaths: context.paths
            ),
            rebound
        )

        var drifted = first
        drifted.append(0x0A)
        XCTAssertThrowsError(try TrainingArtifactStore.persistPreparedManifest(
            drifted,
            artifact: rebound,
            paths: context.paths
        ))
        XCTAssertEqual(try Data(contentsOf: context.paths.trainingManifestURL), first)
    }

    func testPreparedManifestRejectsAConcurrentCanonicalManifestInsteadOfOverwritingIt() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let original = try makeCompletedPublicationArtifact(in: context)
        try TrainingArtifactStore.persist(original, paths: context.paths)
        try FileManager.default.copyItem(
            at: context.paths.msplatOutputURL,
            to: context.paths.outputSplatURL
        )
        var rebound = original
        rebound.outputPath = "Output/splat.ply"
        let prepared = try TrainingArtifactStore.encodedManifestData(
            rebound,
            projectPaths: context.paths
        )
        var concurrent = original
        concurrent.cameraOrderSeed += 1
        let concurrentData = try TrainingArtifactStore.encodedManifestData(
            concurrent,
            projectPaths: context.paths
        )

        XCTAssertThrowsError(try TrainingArtifactStore.persistPreparedManifest(
            prepared,
            artifact: rebound,
            validatedOutputEvidence: ProjectArtifactValidator.validatedPlyEvidence(
                at: context.paths.outputSplatURL
            ),
            paths: context.paths,
            operations: TrainingFilesystemOperations { checkpoint in
                guard checkpoint == .preparedManifestDirectoryBound else { return }
                try concurrentData.write(
                    to: context.paths.trainingManifestURL,
                    options: .atomic
                )
            }
        ))

        XCTAssertEqual(
            try Data(contentsOf: context.paths.trainingManifestURL),
            concurrentData
        )
    }

    func testPreparedManifestRejectsByteIdenticalCanonicalIdentityReplacement() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let original = try makeCompletedPublicationArtifact(in: context)
        try TrainingArtifactStore.persist(original, paths: context.paths)
        let originalData = try Data(contentsOf: context.paths.trainingManifestURL)
        try FileManager.default.copyItem(
            at: context.paths.msplatOutputURL,
            to: context.paths.outputSplatURL
        )
        var rebound = original
        rebound.outputPath = "Output/splat.ply"
        let prepared = try TrainingArtifactStore.encodedManifestData(
            rebound,
            projectPaths: context.paths
        )

        XCTAssertThrowsError(try TrainingArtifactStore.persistPreparedManifest(
            prepared,
            artifact: rebound,
            validatedOutputEvidence: ProjectArtifactValidator.validatedPlyEvidence(
                at: context.paths.outputSplatURL
            ),
            paths: context.paths,
            operations: TrainingFilesystemOperations { checkpoint in
                guard checkpoint == .preparedManifestDirectoryBound else { return }
                try originalData.write(
                    to: context.paths.trainingManifestURL,
                    options: .atomic
                )
            }
        ))

        XCTAssertEqual(
            try Data(contentsOf: context.paths.trainingManifestURL),
            originalData
        )
    }

    func testPreparedManifestInstallRaceRestoresTheExactDisplacedManifest() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let original = try makeCompletedPublicationArtifact(in: context)
        try TrainingArtifactStore.persist(original, paths: context.paths)
        try FileManager.default.copyItem(
            at: context.paths.msplatOutputURL,
            to: context.paths.outputSplatURL
        )
        var rebound = original
        rebound.outputPath = "Output/splat.ply"
        let prepared = try TrainingArtifactStore.encodedManifestData(
            rebound,
            projectPaths: context.paths
        )
        var concurrent = original
        concurrent.cameraOrderSeed += 1
        let concurrentData = try TrainingArtifactStore.encodedManifestData(
            concurrent,
            projectPaths: context.paths
        )

        XCTAssertThrowsError(try TrainingArtifactStore.persistPreparedManifest(
            prepared,
            artifact: rebound,
            validatedOutputEvidence: ProjectArtifactValidator.validatedPlyEvidence(
                at: context.paths.outputSplatURL
            ),
            paths: context.paths,
            operations: TrainingFilesystemOperations { checkpoint in
                guard checkpoint == .preparedManifestReadyToInstall else { return }
                try concurrentData.write(
                    to: context.paths.trainingManifestURL,
                    options: .atomic
                )
            }
        ))

        XCTAssertEqual(
            try Data(contentsOf: context.paths.trainingManifestURL),
            concurrentData
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: context.paths.trainingURL.path)
                .contains(where: { $0.hasPrefix(".training-manifest.") })
        )
    }

    func testPreparedManifestRejectsGeometryMutationAfterPlyInstallation() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let original = try makeCompletedPublicationArtifact(in: context)
        try TrainingArtifactStore.persist(original, paths: context.paths)
        let originalManifest = try Data(contentsOf: context.paths.trainingManifestURL)
        try FileManager.default.copyItem(
            at: context.paths.msplatOutputURL,
            to: context.paths.outputSplatURL
        )
        var rebound = original
        rebound.outputPath = "Output/splat.ply"
        let prepared = try TrainingArtifactStore.encodedManifestData(
            rebound,
            projectPaths: context.paths
        )
        var changedGeometry = try GeometryArtifactStore.loadManifest(
            from: context.paths.geometryManifestURL,
            projectPaths: context.paths
        )
        changedGeometry.totalViewCount += 1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let changedGeometryData = try encoder.encode(changedGeometry)

        XCTAssertThrowsError(try TrainingArtifactStore.persistPreparedManifest(
            prepared,
            artifact: rebound,
            validatedOutputEvidence: ProjectArtifactValidator.validatedPlyEvidence(
                at: context.paths.outputSplatURL
            ),
            paths: context.paths,
            operations: TrainingFilesystemOperations { checkpoint in
                guard checkpoint == .preparedManifestDirectoryBound else { return }
                try changedGeometryData.write(
                    to: context.paths.geometryManifestURL,
                    options: .atomic
                )
            }
        ))

        XCTAssertEqual(
            try Data(contentsOf: context.paths.geometryManifestURL),
            changedGeometryData
        )
        XCTAssertEqual(
            try Data(contentsOf: context.paths.trainingManifestURL),
            originalManifest
        )
    }

    func testPreparedManifestPostSwapLineageConflictRestoresExactOriginalManifest() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let original = try makeCompletedPublicationArtifact(in: context)
        try TrainingArtifactStore.persist(original, paths: context.paths)
        let originalManifest = try Data(contentsOf: context.paths.trainingManifestURL)
        var originalStatus = stat()
        XCTAssertEqual(lstat(context.paths.trainingManifestURL.path, &originalStatus), 0)
        try FileManager.default.copyItem(
            at: context.paths.msplatOutputURL,
            to: context.paths.outputSplatURL
        )
        var rebound = original
        rebound.outputPath = "Output/splat.ply"
        let prepared = try TrainingArtifactStore.encodedManifestData(
            rebound,
            projectPaths: context.paths
        )
        var changedGeometry = try GeometryArtifactStore.loadManifest(
            from: context.paths.geometryManifestURL,
            projectPaths: context.paths
        )
        changedGeometry.totalViewCount += 1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let changedGeometryData = try encoder.encode(changedGeometry)

        XCTAssertThrowsError(try TrainingArtifactStore.persistPreparedManifest(
            prepared,
            artifact: rebound,
            validatedOutputEvidence: ProjectArtifactValidator.validatedPlyEvidence(
                at: context.paths.outputSplatURL
            ),
            paths: context.paths,
            operations: TrainingFilesystemOperations { checkpoint in
                guard checkpoint == .preparedManifestInstalled else { return }
                try changedGeometryData.write(
                    to: context.paths.geometryManifestURL,
                    options: .atomic
                )
            }
        ))

        XCTAssertEqual(
            try Data(contentsOf: context.paths.geometryManifestURL),
            changedGeometryData
        )
        var restoredStatus = stat()
        XCTAssertEqual(lstat(context.paths.trainingManifestURL.path, &restoredStatus), 0)
        XCTAssertEqual(restoredStatus.st_dev, originalStatus.st_dev)
        XCTAssertEqual(restoredStatus.st_ino, originalStatus.st_ino)
        XCTAssertEqual(
            try Data(contentsOf: context.paths.trainingManifestURL),
            originalManifest
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: context.paths.trainingURL.path)
                .contains(where: { $0.hasPrefix(".training-manifest.") })
        )
    }

    func testPreparedManifestRollbackRefusesAtomicallyReplacedDisplacedSource() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let original = try makeCompletedPublicationArtifact(in: context)
        try TrainingArtifactStore.persist(original, paths: context.paths)
        try FileManager.default.copyItem(
            at: context.paths.msplatOutputURL,
            to: context.paths.outputSplatURL
        )
        var rebound = original
        rebound.outputPath = PublishedSplatReceipt.canonicalOutputPath
        let prepared = try TrainingArtifactStore.encodedManifestData(
            rebound,
            projectPaths: context.paths
        )
        var foreign = original
        foreign.cameraOrderSeed += 1
        let foreignData = try TrainingArtifactStore.encodedManifestData(
            foreign,
            projectPaths: context.paths
        )

        XCTAssertThrowsError(try TrainingArtifactStore.persistPreparedManifest(
            prepared,
            artifact: rebound,
            validatedOutputEvidence: ProjectArtifactValidator.validatedPlyEvidence(
                at: context.paths.outputSplatURL
            ),
            paths: context.paths,
            operations: TrainingFilesystemOperations { checkpoint in
                guard checkpoint == .preparedManifestInstalled else { return }
                let names = try FileManager.default.contentsOfDirectory(
                    atPath: context.paths.trainingURL.path
                )
                let temporaryNames = names.filter {
                    $0.hasPrefix(".training-manifest.") && $0.hasSuffix(".tmp")
                }
                guard temporaryNames.count == 1,
                      let temporaryName = temporaryNames.first else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
                let temporary = context.paths.trainingURL.appendingPathComponent(temporaryName)
                let replacement = context.paths.trainingURL.appendingPathComponent(
                    ".foreign-prepared-manifest.\(UUID().uuidString).tmp"
                )
                try foreignData.write(to: replacement, options: .withoutOverwriting)
                guard Darwin.chmod(replacement.path, mode_t(0o600)) == 0,
                      Darwin.rename(replacement.path, temporary.path) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                throw CleanupCrash.injected
            }
        ))

        XCTAssertEqual(try Data(contentsOf: context.paths.trainingManifestURL), prepared)
        XCTAssertNotEqual(try Data(contentsOf: context.paths.trainingManifestURL), foreignData)
    }

    func testPreparedManifestRollbackRefusesSameInodeMutationWithRestoredSizeAndMtime() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let original = try makeCompletedPublicationArtifact(in: context)
        try TrainingArtifactStore.persist(original, paths: context.paths)
        let originalData = try Data(contentsOf: context.paths.trainingManifestURL)
        try FileManager.default.copyItem(
            at: context.paths.msplatOutputURL,
            to: context.paths.outputSplatURL
        )
        var rebound = original
        rebound.outputPath = PublishedSplatReceipt.canonicalOutputPath
        let prepared = try TrainingArtifactStore.encodedManifestData(
            rebound,
            projectPaths: context.paths
        )
        var foreign = original
        foreign.cameraOrderSeed += 1
        let foreignData = try TrainingArtifactStore.encodedManifestData(
            foreign,
            projectPaths: context.paths
        )
        XCTAssertEqual(foreignData.count, originalData.count)

        XCTAssertThrowsError(try TrainingArtifactStore.persistPreparedManifest(
            prepared,
            artifact: rebound,
            validatedOutputEvidence: ProjectArtifactValidator.validatedPlyEvidence(
                at: context.paths.outputSplatURL
            ),
            paths: context.paths,
            operations: TrainingFilesystemOperations { checkpoint in
                guard checkpoint == .preparedManifestInstalled else { return }
                let names = try FileManager.default.contentsOfDirectory(
                    atPath: context.paths.trainingURL.path
                )
                let temporaryNames = names.filter {
                    $0.hasPrefix(".training-manifest.") && $0.hasSuffix(".tmp")
                }
                guard temporaryNames.count == 1,
                      let temporaryName = temporaryNames.first else {
                    throw TrainingArtifactStoreError.invalidManifest
                }
                let temporary = context.paths.trainingURL.appendingPathComponent(temporaryName)
                let descriptor = Darwin.open(
                    temporary.path,
                    O_RDWR | O_NOFOLLOW | O_CLOEXEC
                )
                guard descriptor >= 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                defer { Darwin.close(descriptor) }
                var before = stat()
                guard Darwin.fstat(descriptor, &before) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                let written = foreignData.withUnsafeBytes { bytes in
                    Darwin.pwrite(descriptor, bytes.baseAddress, bytes.count, 0)
                }
                guard written == foreignData.count,
                      Darwin.ftruncate(descriptor, off_t(foreignData.count)) == 0,
                      Darwin.fsync(descriptor) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                var originalTimes = [before.st_atimespec, before.st_mtimespec]
                guard Darwin.futimens(descriptor, &originalTimes) == 0,
                      Darwin.fsync(descriptor) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                var after = stat()
                guard Darwin.fstat(descriptor, &after) == 0,
                      after.st_dev == before.st_dev,
                      after.st_ino == before.st_ino,
                      after.st_size == before.st_size,
                      after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
                      after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
                      after.st_ctimespec.tv_sec != before.st_ctimespec.tv_sec
                        || after.st_ctimespec.tv_nsec != before.st_ctimespec.tv_nsec else {
                    throw CleanupCrash.injected
                }
                throw CleanupCrash.injected
            }
        ))

        XCTAssertEqual(try Data(contentsOf: context.paths.trainingManifestURL), prepared)
        XCTAssertNotEqual(try Data(contentsOf: context.paths.trainingManifestURL), foreignData)
    }

    func testPreparedManifestRetryIsIdempotentAndKeepsCanonicalIdentity() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let original = try makeCompletedPublicationArtifact(in: context)
        try TrainingArtifactStore.persist(original, paths: context.paths)
        try FileManager.default.copyItem(
            at: context.paths.msplatOutputURL,
            to: context.paths.outputSplatURL
        )
        var rebound = original
        rebound.outputPath = "Output/splat.ply"
        let prepared = try TrainingArtifactStore.encodedManifestData(
            rebound,
            projectPaths: context.paths
        )
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(
            at: context.paths.outputSplatURL
        )
        try TrainingArtifactStore.persistPreparedManifest(
            prepared,
            artifact: rebound,
            validatedOutputEvidence: evidence,
            paths: context.paths
        )
        var firstStatus = stat()
        XCTAssertEqual(lstat(context.paths.trainingManifestURL.path, &firstStatus), 0)

        try TrainingArtifactStore.persistPreparedManifest(
            prepared,
            artifact: rebound,
            validatedOutputEvidence: evidence,
            paths: context.paths
        )

        var secondStatus = stat()
        XCTAssertEqual(lstat(context.paths.trainingManifestURL.path, &secondStatus), 0)
        XCTAssertEqual(secondStatus.st_dev, firstStatus.st_dev)
        XCTAssertEqual(secondStatus.st_ino, firstStatus.st_ino)
        XCTAssertEqual(try Data(contentsOf: context.paths.trainingManifestURL), prepared)
    }

    func testDescriptorBoundManifestEncodingDoesNotConsultReplacedProjectPath() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let completed = try makeCompletedPublicationArtifact(in: context)
        try TrainingArtifactStore.persist(completed, paths: context.paths)
        var rebound = completed
        rebound.outputPath = PublishedSplatReceipt.canonicalOutputPath
        let expected = try TrainingArtifactStore.encodedManifestData(
            rebound,
            projectPaths: context.paths
        )
        let originalManifest = try Data(
            contentsOf: context.paths.trainingManifestURL
        )
        let projectDescriptor = Darwin.open(
            context.root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard projectDescriptor >= 0 else {
            return XCTFail("Could not bind the original project root")
        }
        defer { Darwin.close(projectDescriptor) }

        let displacedRoot = context.root.deletingLastPathComponent()
            .appendingPathComponent(
                "DescriptorBoundEncoding-displaced.easysplatproj",
                isDirectory: true
            )
        try FileManager.default.moveItem(at: context.root, to: displacedRoot)
        let replacementPaths = ProjectPaths(root: context.root)
        try replacementPaths.ensureDirectories()
        let replacementMarker = replacementPaths.trainingURL
            .appendingPathComponent("replacement.txt")
        let replacementBytes = Data("replacement project".utf8)
        try replacementBytes.write(to: replacementMarker)

        let encoded = try TrainingArtifactStore.encodedManifestData(
            rebound,
            projectPaths: context.paths,
            projectRootDescriptor: projectDescriptor
        )

        XCTAssertEqual(encoded, expected)
        XCTAssertEqual(try Data(contentsOf: replacementMarker), replacementBytes)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: replacementPaths.trainingManifestURL.path
            )
        )
        XCTAssertEqual(
            try Data(
                contentsOf: ProjectPaths(root: displacedRoot)
                    .trainingManifestURL
            ),
            originalManifest
        )
    }

    func testPreparedManifestTrainingSwapCannotWriteOutsideProject() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let completed = try makeCompletedPublicationArtifact(in: context)
        try TrainingArtifactStore.persist(completed, paths: context.paths)
        var rebound = completed
        rebound.outputPath = "Output/splat.ply"
        try FileManager.default.copyItem(
            at: context.paths.msplatOutputURL,
            to: context.paths.outputSplatURL
        )
        let prepared = try TrainingArtifactStore.encodedManifestData(
            rebound,
            projectPaths: context.paths
        )
        let originalTraining = context.paths.trainingURL
        let displacedTraining = context.root.deletingLastPathComponent()
            .appendingPathComponent("DisplacedTraining-\(UUID().uuidString)", isDirectory: true)
        let externalTraining = context.root.deletingLastPathComponent()
            .appendingPathComponent("ExternalTraining-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: externalTraining, withIntermediateDirectories: true)
        let externalMarker = externalTraining.appendingPathComponent("keep.txt")
        let markerBytes = Data("outside must survive".utf8)
        try markerBytes.write(to: externalMarker)

        XCTAssertThrowsError(try TrainingArtifactStore.persistPreparedManifest(
            prepared,
            artifact: rebound,
            validatedOutputEvidence: ProjectArtifactValidator.validatedPlyEvidence(
                at: context.paths.outputSplatURL
            ),
            paths: context.paths,
            operations: TrainingFilesystemOperations { checkpoint in
                guard checkpoint == .preparedManifestDirectoryBound else { return }
                try FileManager.default.moveItem(
                    at: originalTraining,
                    to: displacedTraining
                )
                try FileManager.default.createSymbolicLink(
                    at: originalTraining,
                    withDestinationURL: externalTraining
                )
            }
        ))

        XCTAssertEqual(try Data(contentsOf: externalMarker), markerBytes)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: externalTraining.appendingPathComponent("training_manifest.json").path
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

    func testArtifactBindsItsActualBudgetToVerifiedLiveAdmission() throws {
        let context = try makeContext()
        defer { context.cleanup() }

        var tamperedAdmission = makeCheckpointedArtifact()
        tamperedAdmission.resourceAdmission.hostCapacityBytes -= 1
        XCTAssertThrowsError(
            try TrainingArtifactStore.save(
                tamperedAdmission,
                to: context.paths.trainingManifestURL,
                projectPaths: context.paths
            )
        )

        var overcommitted = makeCheckpointedArtifact()
        overcommitted.memoryBudgetBytes = Int64(
            overcommitted.resourceAdmission.allowedTrainerBytes
        ) + 1
        XCTAssertThrowsError(
            try TrainingArtifactStore.save(
                overcommitted,
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

    func testCompletedArtifactRejectsSceneBoundsNotDerivedFromOutput() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        var forged = try makeCompletedArtifact(in: context)
        forged.sceneBounds = SplatSceneBounds(
            center: .init(x: 10_000, y: -20_000, z: 30_000),
            radius: 1_000_000
        )

        XCTAssertThrowsError(
            try TrainingArtifactStore.save(
                forged,
                to: context.paths.trainingManifestURL,
                projectPaths: context.paths
            )
        )
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
        for schema in 1..<TrainingArtifact.currentSchemaVersion {
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
            "datasetDerivation",
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
                "Decoded current training manifest without required field \(field)"
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
            XCTAssertThrowsError(
                try TrainingArtifactStore.persist(
                    artifact,
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

    func testCompletedArtifactBindsPromotedPublicPlyBytes() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let artifact = try makeCompletedArtifact(in: context)
        try TrainingArtifactStore.persist(artifact, paths: context.paths)

        let publicOutput = context.paths.outputURL.appendingPathComponent("splat.ply")
        try FileManager.default.copyItem(at: context.paths.msplatOutputURL, to: publicOutput)
        var promotedArtifact = artifact
        promotedArtifact.outputPath = "Output/splat.ply"
        try TrainingArtifactStore.persist(
            promotedArtifact,
            paths: context.paths
        )

        let original = try String(contentsOf: publicOutput, encoding: .utf8)
        let replaced = original.replacingOccurrences(
            of: "0 0 0 1 1 1",
            with: "1 0 0 1 1 1"
        )
        XCTAssertEqual(replaced.utf8.count, original.utf8.count)
        try replaced.write(to: publicOutput, atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectArtifactValidator.validatePlyFile(at: publicOutput), .valid)

        XCTAssertThrowsError(
            try TrainingArtifactStore.load(
                from: context.paths.trainingManifestURL,
                projectPaths: context.paths
            )
        )
    }

    func testCompletionForDifferentDatasetPreservesPriorArtifactAndPublicOutput() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let metadata = context.metadata
        var priorArtifact = try makeCompletedArtifact(in: context)
        let publicOutput = context.paths.outputURL.appendingPathComponent("splat.ply")
        try FileManager.default.copyItem(at: context.paths.msplatOutputURL, to: publicOutput)
        priorArtifact.outputPath = "Output/splat.ply"
        try TrainingArtifactStore.persist(
            priorArtifact,
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
                    resourceAdmission: makeTestTrainingResourceAdmission(),
                    datasetIdentity: datasetIdentity,
                    datasetDerivation: makeMsplatDatasetDerivation(
                        inputDigest: datasetIdentity.inputDigest,
                        geometryDigest: datasetIdentity.geometryDigest
                    ),
                    paths: context.paths
                )
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

    func testCompletionPersistsBoundsMeasuredFromTrainerOutput() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try TestFileBuilder.writeMinimalPly(at: context.paths.msplatOutputURL)
        let requestedOptions = RequestedRunOptions(
            capturePath: .orbit,
            detailProfile: .balanced
        )
        let plan = RunPlanResolver.resolve(
            requestedOptions: requestedOptions,
            input: context.metadata.input,
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
        let result = MsplatTrainingResult(
            profile: .balanced,
            iterationLimit: plan.trainerIterationLimit,
            plateauWindow: plan.plateauWindow,
            completedIteration: plan.trainerIterationLimit,
            stopReason: .iterationLimit,
            gaussianCount: 1,
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
                center: .init(x: 10_000, y: -20_000, z: 30_000),
                radius: 1_000_000
            ),
            outputBytes: outputBytes,
            inputDigest: datasetIdentity.inputDigest,
            geometryDigest: datasetIdentity.geometryDigest,
            trainerBuildDigest: String(repeating: "a", count: 64),
            latestCheckpoint: nil
        )
        let runner = PipelineRunner(
            projectURL: context.root,
            config: .init(toolchain: TestToolchains.toolchainPaths(root: context.root))
        )

        let artifact = try runner.persistMsplatCompletion(
            result,
            profile: .balanced,
            cameraOrderSeed: plan.runSeed,
            resolvedPlan: plan,
            resourceAdmission: makeTestTrainingResourceAdmission(),
            datasetIdentity: datasetIdentity,
            datasetDerivation: makeMsplatDatasetDerivation(
                inputDigest: datasetIdentity.inputDigest,
                geometryDigest: datasetIdentity.geometryDigest
            ),
            paths: context.paths
        )

        XCTAssertEqual(
            artifact.sceneBounds,
            try SplatSceneBoundsCalculator.compute(
                at: context.paths.msplatOutputURL,
                maximumSampleCount: RobustSplatBounds.maximumFallbackSampleCount
            )
        )
        XCTAssertNotEqual(artifact.sceneBounds, result.sceneBounds)
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

    func testCompletedArtifactValidatesAgainstAlreadyAuthenticatedPlyEvidence() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        let artifact = try makeCompletedArtifact(in: context)
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(
            at: context.paths.msplatOutputURL
        )

        XCTAssertNoThrow(
            try TrainingArtifactStore.validateCompletedOutput(
                artifact,
                evidence: evidence
            )
        )

        var mismatched = artifact
        mismatched.outputSHA256 = String(repeating: "f", count: 64)
        XCTAssertThrowsError(
            try TrainingArtifactStore.validateCompletedOutput(
                mismatched,
                evidence: evidence
            )
        )
    }

    func testDiscardRemovesOnlyCheckpointedResumeRecord() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        var metadata = context.metadata
        try TrainingArtifactStore.persist(
            makeCheckpointedArtifact(),
            paths: context.paths
        )

        try TrainingArtifactStore.discardCheckpointedArtifact(
            metadata: &metadata,
            paths: context.paths
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: context.paths.trainingManifestURL.path))
    }

    func testCheckpointDiscardCrashAfterDirectoryRenameReconcilesOwnedOrphanAndPreservesNewRoot() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try TrainingArtifactStore.persist(
            makeCheckpointedArtifact(),
            paths: context.paths
        )
        let oldPayload = context.paths.msplatCheckpointURL
            .appendingPathComponent("old.bin")
        try Data("old checkpoint".utf8).write(to: oldPayload)
        let cleanupID = UUID(uuidString: "10101010-2020-4030-8040-505050505050")!
        var operations = TrainingFilesystemOperations.live
        operations.makeCleanupID = { cleanupID }
        operations.checkpoint = { checkpoint in
            guard checkpoint == .checkpointDiscardCheckpointRenamed else { return }
            throw CleanupCrash.injected
        }

        XCTAssertThrowsError(
            try TrainingArtifactStore.discardCheckpointedPayload(
                paths: context.paths,
                operations: operations
            )
        )
        let quarantine = checkpointDiscardQuarantineURL(
            paths: context.paths,
            cleanupID: cleanupID,
            suffix: "checkpoints"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: context.paths.checkpointDiscardCleanupJournalURL.path
            )
        )

        try FileManager.default.createDirectory(
            at: context.paths.msplatCheckpointURL,
            withIntermediateDirectories: false
        )
        let newPayload = context.paths.msplatCheckpointURL
            .appendingPathComponent("new.bin")
        let newBytes = Data("new checkpoint".utf8)
        try newBytes.write(to: newPayload)

        XCTAssertEqual(
            try TrainingArtifactStore.reconcileCheckpointDiscardForPipelineStartup(
                paths: context.paths
            ),
            .completed
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
        XCTAssertEqual(try Data(contentsOf: newPayload), newBytes)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: context.paths.checkpointDiscardCleanupJournalURL.path
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.paths.trainingManifestURL.path))
    }

    func testCheckpointDiscardCrashAfterRegularManifestRenameReconcilesExactFile() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try TrainingArtifactStore.persist(
            makeCheckpointedArtifact(),
            paths: context.paths
        )
        try FileManager.default.removeItem(at: context.paths.msplatCheckpointURL)
        let cleanupID = UUID(uuidString: "20202020-3030-4040-8050-606060606060")!
        var operations = TrainingFilesystemOperations.live
        operations.makeCleanupID = { cleanupID }
        operations.checkpoint = { checkpoint in
            guard checkpoint == .checkpointDiscardManifestRenamed else { return }
            throw CleanupCrash.injected
        }

        XCTAssertThrowsError(
            try TrainingArtifactStore.discardCheckpointedPayload(
                paths: context.paths,
                operations: operations
            )
        )
        let quarantine = checkpointDiscardQuarantineURL(
            paths: context.paths,
            cleanupID: cleanupID,
            suffix: "manifest"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantine.path))

        XCTAssertEqual(
            try TrainingArtifactStore.reconcileCheckpointDiscardForPipelineStartup(
                paths: context.paths
            ),
            .completed
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: quarantine.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.paths.trainingManifestURL.path))
    }

    func testCheckpointDiscardCrashAfterSymlinkManifestRenameNeverTouchesTarget() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try TrainingArtifactStore.persist(
            makeCheckpointedArtifact(),
            paths: context.paths
        )
        try FileManager.default.removeItem(at: context.paths.msplatCheckpointURL)
        try FileManager.default.removeItem(at: context.paths.trainingManifestURL)
        let outside = context.root.deletingLastPathComponent()
            .appendingPathComponent("checkpoint-manifest-target-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        let outsideBytes = Data("preserve target".utf8)
        try outsideBytes.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: context.paths.trainingManifestURL,
            withDestinationURL: outside
        )
        let cleanupID = UUID(uuidString: "30303030-4040-4050-8060-707070707070")!
        var operations = TrainingFilesystemOperations.live
        operations.makeCleanupID = { cleanupID }
        operations.checkpoint = { checkpoint in
            guard checkpoint == .checkpointDiscardManifestRenamed else { return }
            throw CleanupCrash.injected
        }

        XCTAssertThrowsError(
            try TrainingArtifactStore.discardCheckpointedPayload(
                paths: context.paths,
                operations: operations
            )
        )
        XCTAssertEqual(try Data(contentsOf: outside), outsideBytes)

        XCTAssertEqual(
            try TrainingArtifactStore.reconcileCheckpointDiscardForPipelineStartup(
                paths: context.paths
            ),
            .completed
        )
        XCTAssertEqual(try Data(contentsOf: outside), outsideBytes)
        XCTAssertNil(
            try? FileManager.default.destinationOfSymbolicLink(
                atPath: context.paths.trainingManifestURL.path
            )
        )
    }

    func testCheckpointDiscardForeignQuarantineIsPreservedAsConflict() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try TrainingArtifactStore.persist(
            makeCheckpointedArtifact(),
            paths: context.paths
        )
        let cleanupID = UUID(uuidString: "40404040-5050-4060-8070-808080808080")!
        var operations = TrainingFilesystemOperations.live
        operations.makeCleanupID = { cleanupID }
        operations.checkpoint = { checkpoint in
            guard checkpoint == .checkpointDiscardCheckpointRenamed else { return }
            throw CleanupCrash.injected
        }
        XCTAssertThrowsError(
            try TrainingArtifactStore.discardCheckpointedPayload(
                paths: context.paths,
                operations: operations
            )
        )
        let quarantine = checkpointDiscardQuarantineURL(
            paths: context.paths,
            cleanupID: cleanupID,
            suffix: "checkpoints"
        )
        let displaced = context.paths.trainingURL.appendingPathComponent(
            ".test-displaced-checkpoint-cleanup",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: quarantine, to: displaced)
        let foreignSentinel = quarantine.appendingPathComponent("foreign.bin")
        try FileManager.default.createDirectory(
            at: quarantine,
            withIntermediateDirectories: false
        )
        let foreignBytes = Data("foreign quarantine".utf8)
        try foreignBytes.write(to: foreignSentinel)

        XCTAssertEqual(
            try TrainingArtifactStore.reconcileCheckpointDiscardForPipelineStartup(
                paths: context.paths
            ),
            .deferredConflict
        )
        XCTAssertEqual(try Data(contentsOf: foreignSentinel), foreignBytes)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: context.paths.checkpointDiscardCleanupJournalURL.path
            )
        )
    }

    func testCheckpointDiscardMalformedJournalAuthorizesNothing() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try TrainingArtifactStore.persist(
            makeCheckpointedArtifact(),
            paths: context.paths
        )
        let manifestBytes = try Data(contentsOf: context.paths.trainingManifestURL)
        let checkpoint = context.paths.msplatCheckpointURL
            .appendingPathComponent("state.bin")
        let checkpointBytes = Data("checkpoint".utf8)
        try checkpointBytes.write(to: checkpoint)
        let malformed = Data(
            "{\"schemaVersion\":1,\"cleanupID\":\"40404040-5050-4060-8070-808080808080\",\"unknown\":true}".utf8
        )
        try malformed.write(to: context.paths.checkpointDiscardCleanupJournalURL)
        XCTAssertEqual(
            Darwin.chmod(
                context.paths.checkpointDiscardCleanupJournalURL.path,
                mode_t(0o600)
            ),
            0
        )

        XCTAssertEqual(
            try TrainingArtifactStore.reconcileCheckpointDiscardForPipelineStartup(
                paths: context.paths
            ),
            .deferredConflict
        )
        XCTAssertEqual(
            try Data(contentsOf: context.paths.checkpointDiscardCleanupJournalURL),
            malformed
        )
        XCTAssertEqual(
            try Data(contentsOf: context.paths.trainingManifestURL),
            manifestBytes
        )
        XCTAssertEqual(try Data(contentsOf: checkpoint), checkpointBytes)
    }

    func testCheckpointDiscardJournalFsyncFailurePrecedesEveryRename() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try TrainingArtifactStore.persist(
            makeCheckpointedArtifact(),
            paths: context.paths
        )
        let manifestBytes = try Data(contentsOf: context.paths.trainingManifestURL)
        let checkpoint = context.paths.msplatCheckpointURL
            .appendingPathComponent("state.bin")
        let checkpointBytes = Data("checkpoint".utf8)
        try checkpointBytes.write(to: checkpoint)
        var operations = TrainingFilesystemOperations.live
        operations.synchronizeCleanupFile = { _ in
            errno = EIO
            return -1
        }

        XCTAssertThrowsError(
            try TrainingArtifactStore.discardCheckpointedPayload(
                paths: context.paths,
                operations: operations
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: context.paths.trainingManifestURL),
            manifestBytes
        )
        XCTAssertEqual(try Data(contentsOf: checkpoint), checkpointBytes)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: context.paths.checkpointDiscardCleanupJournalURL.path
            )
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                atPath: context.paths.trainingURL.path
            ).contains(where: { $0.hasPrefix(".checkpoint-discard-cleanup.") })
        )
    }

    func testCheckpointDiscardFailureNeverUnlinksReplacedTemporaryJournal() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try TrainingArtifactStore.persist(
            makeCheckpointedArtifact(),
            paths: context.paths
        )
        let cleanupID = UUID(uuidString: "51515151-6262-4373-8484-959595959595")!
        let temporary = context.paths.trainingURL.appendingPathComponent(
            ".checkpoint-discard-cleanup.\(cleanupID.uuidString).journal.tmp"
        )
        let displaced = context.paths.trainingURL.appendingPathComponent(
            ".test-displaced-checkpoint-journal"
        )
        let foreignBytes = Data("foreign temporary journal".utf8)
        var operations = TrainingFilesystemOperations.live
        operations.makeCleanupID = { cleanupID }
        operations.synchronizeCleanupFile = { _ in
            do {
                try FileManager.default.moveItem(at: temporary, to: displaced)
                try foreignBytes.write(to: temporary)
                guard Darwin.chmod(temporary.path, mode_t(0o600)) == 0 else {
                    return -1
                }
            } catch {
                return -1
            }
            errno = EIO
            return -1
        }

        XCTAssertThrowsError(
            try TrainingArtifactStore.discardCheckpointedPayload(
                paths: context.paths,
                operations: operations
            )
        )
        XCTAssertEqual(try Data(contentsOf: temporary), foreignBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: displaced.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: context.paths.msplatCheckpointURL.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: context.paths.trainingManifestURL.path
            )
        )
    }

    func testCheckpointDiscardJournalPublicationNeverOverwritesRacingFile() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try TrainingArtifactStore.persist(
            makeCheckpointedArtifact(),
            paths: context.paths
        )
        let manifestBytes = try Data(contentsOf: context.paths.trainingManifestURL)
        let foreignBytes = Data("foreign journal".utf8)
        let liveRename = TrainingFilesystemOperations.live.renameCleanupExclusive
        var operations = TrainingFilesystemOperations.live
        operations.renameCleanupExclusive = {
            sourceDirectory,
            source,
            destinationDirectory,
            destination in
            if destination == ".checkpoint-discard-cleanup.json" {
                let descriptor = destination.withCString {
                    Darwin.openat(
                        destinationDirectory,
                        $0,
                        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                        mode_t(0o600)
                    )
                }
                if descriptor >= 0 {
                    _ = foreignBytes.withUnsafeBytes { bytes in
                        Darwin.write(
                            descriptor,
                            bytes.baseAddress,
                            bytes.count
                        )
                    }
                    _ = Darwin.fsync(descriptor)
                    Darwin.close(descriptor)
                    _ = Darwin.fsync(destinationDirectory)
                }
            }
            return liveRename(
                sourceDirectory,
                source,
                destinationDirectory,
                destination
            )
        }

        XCTAssertThrowsError(
            try TrainingArtifactStore.discardCheckpointedPayload(
                paths: context.paths,
                operations: operations
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: context.paths.checkpointDiscardCleanupJournalURL),
            foreignBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: context.paths.trainingManifestURL),
            manifestBytes
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: context.paths.msplatCheckpointURL.path
            )
        )
    }

    func testCheckpointDiscardCrashAfterJournalUnlinkIsAlreadyConverged() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try TrainingArtifactStore.persist(
            makeCheckpointedArtifact(),
            paths: context.paths
        )
        var operations = TrainingFilesystemOperations.live
        operations.checkpoint = { checkpoint in
            guard checkpoint == .checkpointDiscardJournalUnlinked else { return }
            throw CleanupCrash.injected
        }

        XCTAssertThrowsError(
            try TrainingArtifactStore.discardCheckpointedPayload(
                paths: context.paths,
                operations: operations
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: context.paths.checkpointDiscardCleanupJournalURL.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: context.paths.msplatCheckpointURL.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: context.paths.trainingManifestURL.path
            )
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                atPath: context.paths.trainingURL.path
            ).contains(where: { $0.hasPrefix(".checkpoint-discard-cleanup.") })
        )
        XCTAssertEqual(
            try TrainingArtifactStore.reconcileCheckpointDiscardForPipelineStartup(
                paths: context.paths
            ),
            .noJournal
        )
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
    }

    func testCheckpointDiscardIntermediateDirectorySwapCannotDeleteExternalPayload() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        var metadata = context.metadata
        try TrainingArtifactStore.persist(
            makeCheckpointedArtifact(),
            paths: context.paths
        )
        let internalCheckpoint = context.paths.msplatCheckpointURL
            .appendingPathComponent("state.bin")
        try Data("internal checkpoint".utf8).write(to: internalCheckpoint)

        let checkpoints = context.paths.trainingURL
            .appendingPathComponent("checkpoints", isDirectory: true)
        let displacedCheckpoints = context.paths.trainingURL
            .appendingPathComponent("checkpoints-displaced", isDirectory: true)
        let externalCheckpoints = context.root.deletingLastPathComponent()
            .appendingPathComponent("ExternalCheckpoints-\(UUID().uuidString)", isDirectory: true)
        let externalSentinel = externalCheckpoints
            .appendingPathComponent("msplat/keep.txt")
        let externalBytes = Data("outside must survive".utf8)
        try FileManager.default.createDirectory(
            at: externalSentinel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try externalBytes.write(to: externalSentinel)
        let metadataBeforeDiscard = try Data(contentsOf: context.paths.metadataURL)

        XCTAssertThrowsError(try TrainingArtifactStore.discardCheckpointedArtifact(
            metadata: &metadata,
            paths: context.paths,
            operations: TrainingFilesystemOperations { checkpoint in
                guard checkpoint == .checkpointDiscardDirectoryBound else { return }
                try FileManager.default.moveItem(
                    at: checkpoints,
                    to: displacedCheckpoints
                )
                try FileManager.default.createSymbolicLink(
                    at: checkpoints,
                    withDestinationURL: externalCheckpoints
                )
            }
        ))

        XCTAssertEqual(try Data(contentsOf: externalSentinel), externalBytes)
        XCTAssertEqual(
            try Data(contentsOf: displacedCheckpoints.appendingPathComponent("msplat/state.bin")),
            Data("internal checkpoint".utf8)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.paths.trainingManifestURL.path))
        XCTAssertEqual(try Data(contentsOf: context.paths.metadataURL), metadataBeforeDiscard)
    }

    func testDiscardRemovesReservedManifestSymlinkWithoutTouchingTarget() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        var metadata = context.metadata
        try TrainingArtifactStore.persist(
            makeCheckpointedArtifact(),
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

        XCTAssertNil(
            try? FileManager.default.destinationOfSymbolicLink(
                atPath: context.paths.trainingManifestURL.path
            )
        )
        XCTAssertEqual(try Data(contentsOf: outside), sentinel)
    }

    func testDiscardCompletedArtifactRejectsTrainingSymlinkAndPreservesPublicOutput() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        var metadata = context.metadata
        try TrainingArtifactStore.persist(
            try makeCompletedArtifact(in: context),
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

        XCTAssertThrowsError(try TrainingArtifactStore.discardCompletedArtifact(
            metadata: &metadata,
            paths: context.paths
        ))

        XCTAssertNotNil(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: context.paths.trainingURL.path
            )
        )
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: publicOutput), publicBytes)
    }

    func testDiscardCompletedArtifactRemovesOnlyBoundTrainingContents() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        var metadata = context.metadata
        try TrainingArtifactStore.persist(
            try makeCompletedArtifact(in: context),
            paths: context.paths
        )
        let publicOutput = context.paths.outputURL.appendingPathComponent("splat.ply")
        let publicBytes = Data("validated public output".utf8)
        try publicBytes.write(to: publicOutput)

        try TrainingArtifactStore.discardCompletedArtifact(
            metadata: &metadata,
            paths: context.paths
        )

        var trainingStatus = stat()
        XCTAssertEqual(lstat(context.paths.trainingURL.path, &trainingStatus), 0)
        XCTAssertEqual(trainingStatus.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: context.paths.trainingURL.path),
            []
        )
        XCTAssertEqual(try Data(contentsOf: publicOutput), publicBytes)
    }

    func testCompletedDiscardIntermediateCheckpointSwapPreservesExternalPayload() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        var metadata = context.metadata
        try TrainingArtifactStore.persist(
            try makeCompletedArtifact(in: context),
            paths: context.paths
        )
        let checkpoints = context.paths.trainingURL
            .appendingPathComponent("checkpoints", isDirectory: true)
        let displacedCheckpoints = context.paths.trainingURL
            .appendingPathComponent("completed-checkpoints-displaced", isDirectory: true)
        let externalCheckpoints = context.root.deletingLastPathComponent()
            .appendingPathComponent("CompletedExternal-\(UUID().uuidString)", isDirectory: true)
        let externalSentinel = externalCheckpoints
            .appendingPathComponent("msplat/keep.txt")
        let externalBytes = Data("outside must survive".utf8)
        try FileManager.default.createDirectory(
            at: externalSentinel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try externalBytes.write(to: externalSentinel)
        let manifestBeforeDiscard = try Data(contentsOf: context.paths.trainingManifestURL)

        XCTAssertThrowsError(try TrainingArtifactStore.discardCompletedArtifact(
            metadata: &metadata,
            paths: context.paths,
            operations: TrainingFilesystemOperations { checkpoint in
                guard checkpoint == .completedDiscardDirectoryBound else { return }
                try FileManager.default.moveItem(
                    at: checkpoints,
                    to: displacedCheckpoints
                )
                try FileManager.default.createSymbolicLink(
                    at: checkpoints,
                    withDestinationURL: externalCheckpoints
                )
            }
        ))

        XCTAssertEqual(try Data(contentsOf: externalSentinel), externalBytes)
        XCTAssertEqual(try Data(contentsOf: context.paths.trainingManifestURL), manifestBeforeDiscard)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: displacedCheckpoints.appendingPathComponent("msplat").path
            )
        )
    }

    func testDisposableTrainingCleanupRemovesOnlyOwnedPayloads() throws {
        let fixture = try makeCompletedCleanupFixture()
        let context = fixture.context
        defer { context.cleanup() }
        let checkpointPayload = context.paths.msplatCheckpointURL
            .appendingPathComponent("nested/state.bin")
        try FileManager.default.createDirectory(
            at: checkpointPayload.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("checkpoint".utf8).write(to: checkpointPayload)
        try Data("preview".utf8).write(to: context.paths.msplatPreviewURL)
        let strandedPreview = context.paths.msplatPreviewURL.deletingLastPathComponent()
            .appendingPathComponent(".preview.ply.preview.tmp.123.ply")
        try Data("temporary preview".utf8).write(to: strandedPreview)
        let retainedDataset = context.paths.trainingURL
            .appendingPathComponent("msplat_dataset/images/keep.jpg")
        try Data("dataset".utf8).write(to: retainedDataset)
        let runner = PipelineRunner(
            projectURL: context.root,
            config: .init(toolchain: TestToolchains.toolchainPaths(root: context.root))
        )

        try runner.removeDisposableCompletedTrainingPayload(
            paths: context.paths,
            publishedResult: fixture.publication
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: context.paths.msplatCheckpointURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.paths.msplatOutputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.paths.msplatPreviewURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: strandedPreview.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                atPath: context.paths.trainingURL.appendingPathComponent("checkpoints").path
            ).contains(where: { $0.hasPrefix(".training-cleanup.") })
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: context.paths.trainingURL.path)
                .contains(where: { $0.hasPrefix(".completed-training-cleanup.") })
        )
        XCTAssertEqual(try Data(contentsOf: retainedDataset), Data("dataset".utf8))
        XCTAssertEqual(try Data(contentsOf: context.paths.trainingManifestURL), fixture.manifestBytes)
    }

    func testDisposableTrainingCleanupTrainingSwapCannotDeleteExternalPayloads() throws {
        let fixture = try makeCompletedCleanupFixture()
        let context = fixture.context
        defer { context.cleanup() }
        let internalCheckpoint = context.paths.msplatCheckpointURL
            .appendingPathComponent("state.bin")
        try Data("internal checkpoint".utf8).write(to: internalCheckpoint)
        try Data("internal preview".utf8).write(to: context.paths.msplatPreviewURL)

        let originalTraining = context.paths.trainingURL
        let displacedTraining = context.root.deletingLastPathComponent()
            .appendingPathComponent("DisplacedCleanup-\(UUID().uuidString)", isDirectory: true)
        let externalTraining = context.root.deletingLastPathComponent()
            .appendingPathComponent("ExternalCleanup-\(UUID().uuidString)", isDirectory: true)
        let externalCheckpoint = externalTraining
            .appendingPathComponent("checkpoints/msplat/state.bin")
        let externalOutput = externalTraining.appendingPathComponent("msplat/splat.ply")
        let externalPreview = externalTraining.appendingPathComponent("msplat/preview.ply")
        try FileManager.default.createDirectory(
            at: externalCheckpoint.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: externalOutput.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let externalBytes = Data("outside must survive".utf8)
        try externalBytes.write(to: externalCheckpoint)
        try externalBytes.write(to: externalOutput)
        try externalBytes.write(to: externalPreview)
        let runner = PipelineRunner(
            projectURL: context.root,
            config: .init(toolchain: TestToolchains.toolchainPaths(root: context.root))
        )

        XCTAssertThrowsError(try runner.removeDisposableCompletedTrainingPayload(
            paths: context.paths,
            publishedResult: fixture.publication,
            operations: TrainingFilesystemOperations { checkpoint in
                guard checkpoint == .disposableCleanupDirectoryBound else { return }
                try FileManager.default.moveItem(
                    at: originalTraining,
                    to: displacedTraining
                )
                try FileManager.default.createSymbolicLink(
                    at: originalTraining,
                    withDestinationURL: externalTraining
                )
            }
        ))

        XCTAssertEqual(try Data(contentsOf: externalCheckpoint), externalBytes)
        XCTAssertEqual(try Data(contentsOf: externalOutput), externalBytes)
        XCTAssertEqual(try Data(contentsOf: externalPreview), externalBytes)
        XCTAssertEqual(
            try Data(contentsOf: displacedTraining.appendingPathComponent(
                "checkpoints/msplat/state.bin"
            )),
            Data("internal checkpoint".utf8)
        )
    }

    func testCheckpointCleanupDepthLimitKeepsCanonicalPayloadAndRetryRejects() throws {
        let fixture = try makeCompletedCleanupFixture()
        let context = fixture.context
        defer { context.cleanup() }
        var deepest = context.paths.msplatCheckpointURL
        for index in 0...64 {
            deepest.appendPathComponent("level-\(index)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: deepest, withIntermediateDirectories: true)
        let sentinel = deepest.appendingPathComponent("keep.bin")
        try Data("checkpoint".utf8).write(to: sentinel)

        XCTAssertThrowsError(
            try TrainingArtifactStore.removeDisposableCompletedPayload(
                paths: context.paths,
                publishedResult: fixture.publication
            )
        )
        assertCheckpointCleanupRemainsCanonical(
            context: context,
            sentinel: sentinel
        )

        XCTAssertThrowsError(
            try TrainingArtifactStore.removeDisposableCompletedPayload(
                paths: context.paths,
                publishedResult: fixture.publication
            )
        )
        assertCheckpointCleanupRemainsCanonical(
            context: context,
            sentinel: sentinel
        )
    }

    func testCheckpointCleanupEntryLimitKeepsCanonicalPayloadAndRetryRejects() throws {
        let fixture = try makeCompletedCleanupFixture()
        let context = fixture.context
        defer { context.cleanup() }
        let checkpointDescriptor = Darwin.open(
            context.paths.msplatCheckpointURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(checkpointDescriptor, 0)
        defer {
            if checkpointDescriptor >= 0 {
                Darwin.close(checkpointDescriptor)
            }
        }
        for index in 0...50_000 {
            let name = String(format: "entry-%05d.bin", index)
            let descriptor = name.withCString {
                Darwin.openat(
                    checkpointDescriptor,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(0o600)
                )
            }
            guard descriptor >= 0 else {
                throw NSError(
                    domain: NSPOSIXErrorDomain,
                    code: Int(errno),
                    userInfo: [NSFilePathErrorKey: name]
                )
            }
            Darwin.close(descriptor)
        }
        let sentinel = context.paths.msplatCheckpointURL
            .appendingPathComponent("entry-50000.bin")

        XCTAssertThrowsError(
            try TrainingArtifactStore.removeDisposableCompletedPayload(
                paths: context.paths,
                publishedResult: fixture.publication
            )
        )
        assertCheckpointCleanupRemainsCanonical(
            context: context,
            sentinel: sentinel
        )

        XCTAssertThrowsError(
            try TrainingArtifactStore.removeDisposableCompletedPayload(
                paths: context.paths,
                publishedResult: fixture.publication
            )
        )
        assertCheckpointCleanupRemainsCanonical(
            context: context,
            sentinel: sentinel
        )
    }

    private func assertCheckpointCleanupRemainsCanonical(
        context: ArtifactStoreTestContext,
        sentinel: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: context.paths.msplatCheckpointURL.path),
            file: file,
            line: line
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sentinel.path),
            file: file,
            line: line
        )
        XCTAssertFalse(
            (try? FileManager.default.contentsOfDirectory(
                atPath: context.paths.msplatCheckpointURL.deletingLastPathComponent().path
            ))?.contains(where: { $0.hasPrefix(".training-cleanup.") }) == true,
            file: file,
            line: line
        )
    }

    func testDisposableCleanupReconcilerNoOpsWhenTrainingDirectoryIsAbsent() throws {
        let root = try TestFileBuilder.makeTempDir()
            .appendingPathComponent("AbsentTraining.easysplatproj", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: root)

        XCTAssertEqual(
            try TrainingArtifactStore.reconcileDisposableCompletedPayload(
                paths: paths,
                authorization: .deferred
            ),
            .noTraining
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.trainingURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: paths.completedTrainingCleanupJournalURL.path
            )
        )
    }

    func testDisposableCleanupCrashAfterIntentDurableRecoversBothTargets() throws {
        let fixture = try makeCompletedCleanupFixture()
        defer { fixture.context.cleanup() }
        var operations = TrainingFilesystemOperations.live
        operations.makeCleanupID = {
            UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        }
        operations.checkpoint = { checkpoint in
            guard checkpoint == .disposableCleanupIntentDurable else { return }
            throw CleanupCrash.injected
        }

        XCTAssertThrowsError(
            try TrainingArtifactStore.removeDisposableCompletedPayload(
                paths: fixture.context.paths,
                publishedResult: fixture.publication,
                operations: operations
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.context.paths.completedTrainingCleanupJournalURL.path
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.context.paths.msplatCheckpointURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.context.paths.msplatOutputURL.path))
        try assertDurableCleanupStateUnchanged(fixture)

        XCTAssertEqual(
            try TrainingArtifactStore.reconcileDisposableCompletedPayload(
                paths: fixture.context.paths,
                authorization: .published(fixture.publication)
            ),
            .completed
        )
        try assertCompletedCleanupConverged(fixture)
    }

    func testDisposableCleanupCrashAfterCheckpointRenameRecovers() throws {
        let fixture = try makeCompletedCleanupFixture()
        defer { fixture.context.cleanup() }
        let cleanupID = UUID(uuidString: "22222222-3333-4444-8555-666666666666")!
        var operations = TrainingFilesystemOperations.live
        operations.makeCleanupID = { cleanupID }
        operations.checkpoint = { checkpoint in
            guard checkpoint == .disposableCleanupCheckpointRenamed else { return }
            throw CleanupCrash.injected
        }

        XCTAssertThrowsError(
            try TrainingArtifactStore.removeDisposableCompletedPayload(
                paths: fixture.context.paths,
                publishedResult: fixture.publication,
                operations: operations
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.context.paths.msplatCheckpointURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: cleanupQuarantineURL(
                    paths: fixture.context.paths,
                    cleanupID: cleanupID,
                    suffix: "checkpoints"
                ).path
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.context.paths.msplatOutputURL.path))
        try assertDurableCleanupStateUnchanged(fixture)

        XCTAssertEqual(
            try TrainingArtifactStore.reconcileDisposableCompletedPayload(
                paths: fixture.context.paths,
                authorization: .published(fixture.publication)
            ),
            .completed
        )
        try assertCompletedCleanupConverged(fixture)
    }

    func testDisposableCleanupCrashAfterMsplatRenameRecovers() throws {
        let fixture = try makeCompletedCleanupFixture()
        defer { fixture.context.cleanup() }
        let cleanupID = UUID(uuidString: "33333333-4444-4555-8666-777777777777")!
        var operations = TrainingFilesystemOperations.live
        operations.makeCleanupID = { cleanupID }
        operations.checkpoint = { checkpoint in
            guard checkpoint == .disposableCleanupMsplatRenamed else { return }
            throw CleanupCrash.injected
        }

        XCTAssertThrowsError(
            try TrainingArtifactStore.removeDisposableCompletedPayload(
                paths: fixture.context.paths,
                publishedResult: fixture.publication,
                operations: operations
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.context.paths.msplatCheckpointURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.context.paths.msplatOutputURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: cleanupQuarantineURL(
                    paths: fixture.context.paths,
                    cleanupID: cleanupID,
                    suffix: "checkpoints"
                ).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: cleanupQuarantineURL(
                    paths: fixture.context.paths,
                    cleanupID: cleanupID,
                    suffix: "msplat"
                ).path
            )
        )
        try assertDurableCleanupStateUnchanged(fixture)

        XCTAssertEqual(
            try TrainingArtifactStore.reconcileDisposableCompletedPayload(
                paths: fixture.context.paths,
                authorization: .published(fixture.publication)
            ),
            .completed
        )
        try assertCompletedCleanupConverged(fixture)
    }

    func testDisposableCleanupCrashMidRetirementConverges() throws {
        let fixture = try makeCompletedCleanupFixture()
        defer { fixture.context.cleanup() }
        var operations = TrainingFilesystemOperations.live
        operations.checkpoint = { checkpoint in
            guard case .disposableCleanupWillRetireEntry(let path) = checkpoint,
                  path.hasSuffix("/nested") else {
                return
            }
            throw CleanupCrash.injected
        }

        XCTAssertThrowsError(
            try TrainingArtifactStore.removeDisposableCompletedPayload(
                paths: fixture.context.paths,
                publishedResult: fixture.publication,
                operations: operations
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.context.paths.completedTrainingCleanupJournalURL.path
            )
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.context.paths.trainingURL.path
            ).filter { $0.hasSuffix(".checkpoints") }
                .contains { quarantine in
                    FileManager.default.fileExists(
                        atPath: fixture.context.paths.trainingURL
                            .appendingPathComponent(quarantine)
                            .appendingPathComponent("nested/checkpoint.bin").path
                    )
                },
            "The fixture must stop after at least one retirement unlink."
        )
        try assertDurableCleanupStateUnchanged(fixture)

        XCTAssertEqual(
            try TrainingArtifactStore.reconcileDisposableCompletedPayload(
                paths: fixture.context.paths,
                authorization: .published(fixture.publication)
            ),
            .completed
        )
        try assertCompletedCleanupConverged(fixture)
    }

    func testDisposableCleanupCrashAfterJournalUnlinkConverges() throws {
        let fixture = try makeCompletedCleanupFixture()
        defer { fixture.context.cleanup() }
        var operations = TrainingFilesystemOperations.live
        operations.checkpoint = { checkpoint in
            guard checkpoint == .disposableCleanupJournalUnlinked else { return }
            throw CleanupCrash.injected
        }

        XCTAssertThrowsError(
            try TrainingArtifactStore.removeDisposableCompletedPayload(
                paths: fixture.context.paths,
                publishedResult: fixture.publication,
                operations: operations
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.context.paths.completedTrainingCleanupJournalURL.path
            )
        )
        try assertDurableCleanupStateUnchanged(fixture)

        XCTAssertEqual(
            try TrainingArtifactStore.reconcileDisposableCompletedPayload(
                paths: fixture.context.paths,
                authorization: .deferred
            ),
            .noJournal
        )
        try assertCompletedCleanupConverged(fixture)
    }

    func testDisposableCleanupJournalPublicationIsExclusive() throws {
        let fixture = try makeCompletedCleanupFixture()
        defer { fixture.context.cleanup() }
        let foreignBytes = Data("{\"foreign\":true}".utf8)
        try foreignBytes.write(
            to: fixture.context.paths.completedTrainingCleanupJournalURL,
            options: .withoutOverwriting
        )
        XCTAssertEqual(
            Darwin.chmod(
                fixture.context.paths.completedTrainingCleanupJournalURL.path,
                mode_t(0o600)
            ),
            0
        )

        XCTAssertThrowsError(
            try TrainingArtifactStore.removeDisposableCompletedPayload(
                paths: fixture.context.paths,
                publishedResult: fixture.publication
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.context.paths.completedTrainingCleanupJournalURL),
            foreignBytes
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.context.paths.msplatCheckpointURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.context.paths.msplatOutputURL.path))
        try assertDurableCleanupStateUnchanged(fixture)
    }

    func testDisposableCleanupTimingOnlyReceiptUpdatePreservesAuthority() throws {
        let fixture = try makeCompletedCleanupFixture()
        defer { fixture.context.cleanup() }
        var operations = TrainingFilesystemOperations.live
        operations.checkpoint = { checkpoint in
            guard checkpoint == .disposableCleanupIntentDurable else { return }
            throw CleanupCrash.injected
        }
        XCTAssertThrowsError(
            try TrainingArtifactStore.removeDisposableCompletedPayload(
                paths: fixture.context.paths,
                publishedResult: fixture.publication,
                operations: operations
            )
        )
        let timingUpdated = try PublishedResultPairStore.recordFirstViewerReadyTiming(
            42.25,
            expectedPublicationID: fixture.publication.receipt.publicationID,
            projectPaths: fixture.context.paths
        )
        guard case .available(let resolvedTimingUpdate) = try
            PublishedResultPairStore.resolve(projectPaths: fixture.context.paths) else {
            return XCTFail("The timing-only receipt update did not resolve.")
        }
        XCTAssertEqual(timingUpdated, resolvedTimingUpdate)

        XCTAssertEqual(
            try TrainingArtifactStore.reconcileDisposableCompletedPayload(
                paths: fixture.context.paths,
                authorization: .published(resolvedTimingUpdate)
            ),
            .completed
        )
        try assertCompletedCleanupConverged(fixture)
    }

    func testDisposableCleanupNewPublicationPreservesNewCanonicalRoots() throws {
        let fixture = try makeCompletedCleanupFixture()
        defer { fixture.context.cleanup() }
        var operations = TrainingFilesystemOperations.live
        operations.checkpoint = { checkpoint in
            guard checkpoint == .disposableCleanupIntentDurable else { return }
            throw CleanupCrash.injected
        }
        XCTAssertThrowsError(
            try TrainingArtifactStore.removeDisposableCompletedPayload(
                paths: fixture.context.paths,
                publishedResult: fixture.publication,
                operations: operations
            )
        )
        try FileManager.default.removeItem(at: fixture.context.paths.msplatCheckpointURL)
        try FileManager.default.removeItem(
            at: fixture.context.paths.msplatOutputURL.deletingLastPathComponent()
        )
        let newCheckpoint = fixture.context.paths.msplatCheckpointURL
            .appendingPathComponent("new-generation.bin")
        let newOutput = fixture.context.paths.msplatOutputURL
        try FileManager.default.createDirectory(
            at: newCheckpoint.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: newOutput.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("new checkpoint".utf8).write(to: newCheckpoint)
        try Data("new output".utf8).write(to: newOutput)
        let newer = publishedResult(
            fixture.publication,
            publicationID: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!,
            viewerReadySeconds: nil
        )

        XCTAssertEqual(
            try TrainingArtifactStore.reconcileDisposableCompletedPayload(
                paths: fixture.context.paths,
                authorization: .published(newer)
            ),
            .completed
        )
        XCTAssertEqual(try Data(contentsOf: newCheckpoint), Data("new checkpoint".utf8))
        XCTAssertEqual(try Data(contentsOf: newOutput), Data("new output".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.context.paths.completedTrainingCleanupJournalURL.path
            )
        )
        try assertDurableCleanupStateUnchanged(fixture)
    }

    func testDisposableCleanupRetiresExactOldQuarantineWhilePreservingNewCanonicalRoots() throws {
        let fixture = try makeCompletedCleanupFixture()
        defer { fixture.context.cleanup() }
        let cleanupID = UUID(uuidString: "55555555-6666-4777-8888-999999999999")!
        var operations = TrainingFilesystemOperations.live
        operations.makeCleanupID = { cleanupID }
        operations.checkpoint = { checkpoint in
            guard checkpoint == .disposableCleanupCheckpointDurable else { return }
            throw CleanupCrash.injected
        }
        XCTAssertThrowsError(
            try TrainingArtifactStore.removeDisposableCompletedPayload(
                paths: fixture.context.paths,
                publishedResult: fixture.publication,
                operations: operations
            )
        )
        let oldQuarantine = cleanupQuarantineURL(
            paths: fixture.context.paths,
            cleanupID: cleanupID,
            suffix: "checkpoints"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldQuarantine.path))

        let newCheckpoint = fixture.context.paths.msplatCheckpointURL
            .appendingPathComponent("new-generation.bin")
        try FileManager.default.createDirectory(
            at: newCheckpoint.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("new checkpoint".utf8).write(to: newCheckpoint)
        try FileManager.default.removeItem(
            at: fixture.context.paths.msplatOutputURL.deletingLastPathComponent()
        )
        let newOutput = fixture.context.paths.msplatOutputURL
        try FileManager.default.createDirectory(
            at: newOutput.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("new output".utf8).write(to: newOutput)
        let newer = publishedResult(
            fixture.publication,
            publicationID: UUID(uuidString: "BBBBBBBB-CCCC-4DDD-8EEE-FFFFFFFFFFFF")!,
            viewerReadySeconds: nil
        )

        XCTAssertEqual(
            try TrainingArtifactStore.reconcileDisposableCompletedPayload(
                paths: fixture.context.paths,
                authorization: .published(newer)
            ),
            .completed
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldQuarantine.path))
        XCTAssertEqual(try Data(contentsOf: newCheckpoint), Data("new checkpoint".utf8))
        XCTAssertEqual(try Data(contentsOf: newOutput), Data("new output".utf8))
        try assertDurableCleanupStateUnchanged(fixture)
    }

    func testDisposableCleanupForeignQuarantineIsPreserved() throws {
        let fixture = try makeCompletedCleanupFixture()
        defer { fixture.context.cleanup() }
        let cleanupID = UUID(uuidString: "44444444-5555-4666-8777-888888888888")!
        let foreign = cleanupQuarantineURL(
            paths: fixture.context.paths,
            cleanupID: cleanupID,
            suffix: "checkpoints"
        )
        let sentinel = foreign.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        try Data("foreign".utf8).write(to: sentinel)
        var operations = TrainingFilesystemOperations.live
        operations.makeCleanupID = { cleanupID }

        XCTAssertThrowsError(
            try TrainingArtifactStore.removeDisposableCompletedPayload(
                paths: fixture.context.paths,
                publishedResult: fixture.publication,
                operations: operations
            )
        )
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("foreign".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.context.paths.msplatCheckpointURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.context.paths.msplatOutputURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.context.paths.completedTrainingCleanupJournalURL.path
            )
        )
        try assertDurableCleanupStateUnchanged(fixture)
    }

    func testDisposableCleanupTrainingParentSwapAfterIntentCannotEscapeBoundRoot() throws {
        let fixture = try makeCompletedCleanupFixture()
        let context = fixture.context
        defer { context.cleanup() }
        let displacedTraining = context.root.deletingLastPathComponent()
            .appendingPathComponent("DisplacedDurableCleanup-\(UUID().uuidString)")
        let externalTraining = context.root.deletingLastPathComponent()
            .appendingPathComponent("ExternalDurableCleanup-\(UUID().uuidString)")
        let externalMarker = externalTraining.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(
            at: externalTraining,
            withIntermediateDirectories: true
        )
        let externalBytes = Data("outside must survive".utf8)
        try externalBytes.write(to: externalMarker)
        var operations = TrainingFilesystemOperations.live
        operations.checkpoint = { checkpoint in
            guard checkpoint == .disposableCleanupIntentDurable else { return }
            guard Darwin.rename(
                context.paths.trainingURL.path,
                displacedTraining.path
            ) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            try FileManager.default.createSymbolicLink(
                at: context.paths.trainingURL,
                withDestinationURL: externalTraining
            )
            throw CleanupCrash.injected
        }

        XCTAssertThrowsError(
            try TrainingArtifactStore.removeDisposableCompletedPayload(
                paths: context.paths,
                publishedResult: fixture.publication,
                operations: operations
            )
        )
        XCTAssertEqual(try Data(contentsOf: externalMarker), externalBytes)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: displacedTraining.appendingPathComponent(
                    ".completed-training-cleanup.json"
                ).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: displacedTraining.appendingPathComponent("msplat/splat.ply").path
            )
        )

        try FileManager.default.removeItem(at: context.paths.trainingURL)
        guard Darwin.rename(displacedTraining.path, context.paths.trainingURL.path) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        XCTAssertEqual(
            try TrainingArtifactStore.reconcileDisposableCompletedPayload(
                paths: context.paths,
                authorization: .published(fixture.publication)
            ),
            .completed
        )
        XCTAssertEqual(try Data(contentsOf: externalMarker), externalBytes)
        try assertCompletedCleanupConverged(fixture)
    }

    func testMalformedCleanupJournalNeverAuthorizesDeletion() throws {
        let fixture = try makeCompletedCleanupFixture()
        defer { fixture.context.cleanup() }
        let malformed = Data("{\"schemaVersion\":1,\"unknown\":true}".utf8)
        try malformed.write(to: fixture.context.paths.completedTrainingCleanupJournalURL)
        XCTAssertEqual(
            Darwin.chmod(
                fixture.context.paths.completedTrainingCleanupJournalURL.path,
                mode_t(0o600)
            ),
            0
        )

        XCTAssertEqual(
            try TrainingArtifactStore.reconcileDisposableCompletedPayload(
                paths: fixture.context.paths,
                authorization: .published(fixture.publication)
            ),
            .deferredConflict
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.context.paths.completedTrainingCleanupJournalURL),
            malformed
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.context.paths.msplatCheckpointURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.context.paths.msplatOutputURL.path))
        try assertDurableCleanupStateUnchanged(fixture)
    }

    func testCleanupJournalFsyncFailurePrecedesEveryRename() throws {
        let fixture = try makeCompletedCleanupFixture()
        defer { fixture.context.cleanup() }
        var operations = TrainingFilesystemOperations.live
        operations.synchronizeCleanupFile = { _ in
            errno = EIO
            return -1
        }

        XCTAssertThrowsError(
            try TrainingArtifactStore.removeDisposableCompletedPayload(
                paths: fixture.context.paths,
                publishedResult: fixture.publication,
                operations: operations
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.context.paths.msplatCheckpointURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.context.paths.msplatOutputURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.context.paths.completedTrainingCleanupJournalURL.path
            )
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: fixture.context.paths.trainingURL.path)
                .contains(where: { $0.hasPrefix(".completed-training-cleanup.") })
        )
        try assertDurableCleanupStateUnchanged(fixture)
    }

    func testDisposableCleanupCancellationBeforeIntentLeavesCanonicalRootsUntouched() throws {
        let fixture = try makeCompletedCleanupFixture()
        defer { fixture.context.cleanup() }
        let cancellation = CleanupCancellationProbe()
        var operations = TrainingFilesystemOperations.live
        operations.checkpoint = { checkpoint in
            guard checkpoint == .disposableCleanupDirectoryBound else { return }
            cancellation.cancel()
        }

        XCTAssertThrowsError(
            try TrainingArtifactStore.removeDisposableCompletedPayload(
                paths: fixture.context.paths,
                publishedResult: fixture.publication,
                operations: operations,
                shouldCancel: { cancellation.isCancelled }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.context.paths.completedTrainingCleanupJournalURL.path
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.context.paths.msplatCheckpointURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.context.paths.msplatOutputURL.path))
        try assertDurableCleanupStateUnchanged(fixture)
    }

    func testDisposableCleanupDefersCancellationAfterIntentUntilCanonicalDisposition() throws {
        let fixture = try makeCompletedCleanupFixture()
        defer { fixture.context.cleanup() }
        let cancellation = CleanupCancellationProbe()
        var operations = TrainingFilesystemOperations.live
        operations.checkpoint = { checkpoint in
            guard checkpoint == .disposableCleanupIntentDurable else { return }
            cancellation.cancel()
        }

        XCTAssertThrowsError(
            try TrainingArtifactStore.removeDisposableCompletedPayload(
                paths: fixture.context.paths,
                publishedResult: fixture.publication,
                operations: operations,
                shouldCancel: { cancellation.isCancelled }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        try assertCompletedCleanupConverged(fixture)
    }

    func testPreviewCleanupLeavesNoUnjournaledQuarantine() throws {
        let context = try makeContext()
        defer { context.cleanup() }
        try Data("preview".utf8).write(to: context.paths.msplatPreviewURL)
        let temporary = context.paths.msplatPreviewURL.deletingLastPathComponent()
            .appendingPathComponent(".preview.ply.preview.tmp.123.ply")
        try Data("temporary".utf8).write(to: temporary)

        try TrainingArtifactStore.removePreviewPayload(paths: context.paths)

        XCTAssertFalse(FileManager.default.fileExists(atPath: context.paths.msplatPreviewURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                atPath: context.paths.msplatPreviewURL.deletingLastPathComponent().path
            ).contains(where: { $0.hasPrefix(".training-cleanup.") })
        )
    }

    private func makeContext() throws -> ArtifactStoreTestContext {
        let root = try TestFileBuilder.makeTempDir()
            .appendingPathComponent("Artifact.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let controlledMetadata = try TestFileBuilder.bindingControlledPhotoInput(
            to: ProjectMetadata(
                title: "Artifact",
                input: .photos(folder: "Originals/Photos"),
                requestedRunOptions: RequestedRunOptions(
                    capturePath: .orbit,
                    detailProfile: .balanced
                )
            ),
            paths: paths
        )
        let metadata = try TestFileBuilder.bindContinuousPhotoSelectionFixture(
            to: controlledMetadata,
            paths: paths
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
            datasetDerivation: makeMsplatDatasetDerivation(
                inputDigest: String(repeating: "b", count: 64),
                geometryDigest: String(repeating: "c", count: 64)
            ),
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
            resourceAdmission: makeTestTrainingResourceAdmission(),
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
        artifact.sceneBounds = try XCTUnwrap(
            SplatSceneBoundsCalculator.compute(
                at: context.paths.msplatOutputURL,
                maximumSampleCount: RobustSplatBounds.maximumFallbackSampleCount
            )
        )
        artifact.completionStatus = .completed
        return artifact
    }

    private func makeCompletedPublicationArtifact(
        in context: ArtifactStoreTestContext
    ) throws -> TrainingArtifact {
        var artifact = try makeCompletedArtifact(in: context)
        let plan = RunPlanResolver.resolve(
            requestedOptions: context.metadata.requestedRunOptions,
            input: context.metadata.input,
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: .none
        )
        artifact.detailProfile = context.metadata.requestedRunOptions.detailProfile
        artifact.iterationLimit = plan.trainerIterationLimit
        artifact.plateauWindow = plan.plateauWindow
        artifact.cameraOrderSeed = plan.runSeed
        artifact.completedIteration = plan.trainerIterationLimit
        artifact.memoryBudgetBytes = min(
            artifact.memoryBudgetBytes,
            plan.trainerMemoryBudgetBytes
        )
        let imageName = "frame_000000.jpg"
        let dataset = context.paths.trainingURL.appendingPathComponent(
            "msplat_dataset",
            isDirectory: true
        )
        let images = dataset.appendingPathComponent("images", isDirectory: true)
        let sparse = dataset.appendingPathComponent("sparse/0", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        try Data("retained image".utf8).write(
            to: images.appendingPathComponent(imageName)
        )
        for name in [
            "cameras.bin",
            "images.bin",
            "points3D.bin",
            MsplatOrientationOverlay.fileName,
        ] {
            try Data("retained \(name)".utf8).write(
                to: sparse.appendingPathComponent(name)
            )
        }
        let identity = try MsplatDatasetIdentity.compute(
            imageDirectory: images,
            sparseDirectory: sparse
        )

        var geometry = makeGeometryArtifact()
        geometry.selectedFramesDigest = String(repeating: "e", count: 64)
        geometry.orderedImageNames = [imageName]
        geometry.orderedImageTimestamps = [nil]
        geometry.registeredViewCount = 1
        geometry.totalViewCount = 1
        geometry.residualProvenance = "colmap-text-tracks-v1"
        geometry.provenance.toolchainVersion = artifact.datasetDerivation.toolchainVersion
        geometry.provenance.solver = artifact.datasetDerivation.colmapProvenance
        let geometryEncoder = JSONEncoder()
        geometryEncoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try geometryEncoder.encode(geometry).write(
            to: context.paths.geometryManifestURL,
            options: .atomic
        )
        let geometryManifestSHA256 = try GeometryArtifactStore.manifestDigest(
            matching: geometry,
            at: context.paths.geometryManifestURL
        )

        artifact.inputDigest = identity.inputDigest
        artifact.geometryDigest = identity.geometryDigest
        artifact.datasetDerivation.sourceGeometryManifestSHA256 = geometryManifestSHA256
        artifact.datasetDerivation.sourceSelectedFramesDigest = geometry.selectedFramesDigest
        artifact.datasetDerivation.registeredImageNames = [imageName]
        artifact.datasetDerivation.datasetInputDigest = identity.inputDigest
        artifact.datasetDerivation.datasetGeometryDigest = identity.geometryDigest
        return artifact
    }

    private func makeCompletedCleanupFixture() throws -> CompletedCleanupFixture {
        let context = try makeContext()
        do {
            let artifact = try makeCompletedPublicationArtifact(in: context)
            try TrainingArtifactStore.persist(artifact, paths: context.paths)

            let checkpointPayload = context.paths.msplatCheckpointURL
                .appendingPathComponent("nested/checkpoint.bin")
            try FileManager.default.createDirectory(
                at: checkpointPayload.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("checkpoint payload".utf8).write(to: checkpointPayload)
            try Data("preview payload".utf8).write(to: context.paths.msplatPreviewURL)

            let retainedDataset = context.paths.trainingURL
                .appendingPathComponent("msplat_dataset/images/frame_000000.jpg")
            let plan = RunPlanResolver.resolve(
                requestedOptions: context.metadata.requestedRunOptions,
                input: context.metadata.input,
                hardware: HardwareProfile(
                    memoryGB: 48,
                    cpuCount: 16,
                    gpuWorkingSetGB: 36
                ),
                developmentOverrides: .none
            )
            let publicationID = UUID(
                uuidString: "99999999-8888-4777-8666-555555555555"
            )!
            let publishedAt = Date(timeIntervalSince1970: 1_767_225_600)
            var metadata = try ProjectMetadataStore.load(
                from: context.paths.metadataURL
            )
            metadata.resolvedRunPlan = plan
            metadata.pendingPublicationID = publicationID
            metadata.stageTimings = [
                StageTimingRecord(
                    stage: .trainSplat,
                    startedAt: publishedAt.addingTimeInterval(-30),
                    durationSeconds: artifact.elapsedSeconds ?? 0
                )
            ]
            try ProjectMetadataStore.save(metadata, to: context.paths.metadataURL)
            let persistedMetadata = try ProjectMetadataStore.load(
                from: context.paths.metadataURL
            )
            let geometry = try GeometryArtifactStore.loadManifest(
                from: context.paths.geometryManifestURL,
                projectPaths: context.paths
            )
            _ = try PublishedResultPublisher.publishCompletedTraining(
                metadata: persistedMetadata,
                resolvedRunPlan: plan,
                geometry: geometry,
                paths: context.paths,
                publicationID: publicationID,
                publishedAt: publishedAt
            )
            let publication: ValidatedPublishedResult
            switch try PublishedResultPairStore.resolve(projectPaths: context.paths) {
            case .available(let resolved):
                publication = resolved
            case .unavailable, .conflict:
                throw TrainingArtifactStoreError.invalidManifest
            }
            let manifestBytes = try Data(contentsOf: context.paths.trainingManifestURL)
            return CompletedCleanupFixture(
                context: context,
                publication: publication,
                outputBytes: try Data(contentsOf: context.paths.outputSplatURL),
                manifestBytes: manifestBytes,
                retainedDatasetURL: retainedDataset,
                retainedDatasetBytes: try Data(contentsOf: retainedDataset)
            )
        } catch {
            context.cleanup()
            throw error
        }
    }

    private func publishedResult(
        _ source: ValidatedPublishedResult,
        publicationID: UUID,
        viewerReadySeconds: Double?
    ) -> ValidatedPublishedResult {
        let old = source.receipt
        let presentation = old.presentation
        let receipt = PublishedSplatReceipt(
            publicationID: publicationID,
            projectID: old.projectID,
            publishedAt: old.publishedAt,
            outputEvidence: old.outputEvidence,
            lineage: old.lineage,
            presentation: PublishedResultPresentation(
                requestedRunOptions: presentation.requestedRunOptions,
                resolvedRunPlan: presentation.resolvedRunPlan,
                reconstruction: presentation.reconstruction,
                orientation: presentation.orientation,
                stageTimings: presentation.stageTimings,
                autoTunerSnapshot: presentation.autoTunerSnapshot,
                trainerVersion: presentation.trainerVersion,
                runtimeVersion: presentation.runtimeVersion,
                completedIteration: presentation.completedIteration,
                trainingDurationSeconds: presentation.trainingDurationSeconds,
                createToViewerReadySeconds: viewerReadySeconds
            )
        )
        return ValidatedPublishedResult(
            receipt: receipt,
            outputURL: source.outputURL,
            outputEvidence: source.outputEvidence
        )
    }

    private func cleanupQuarantineURL(
        paths: ProjectPaths,
        cleanupID: UUID,
        suffix: String
    ) -> URL {
        paths.trainingURL.appendingPathComponent(
            ".completed-training-cleanup.\(cleanupID.uuidString).\(suffix)",
            isDirectory: true
        )
    }

    private func checkpointDiscardQuarantineURL(
        paths: ProjectPaths,
        cleanupID: UUID,
        suffix: String
    ) -> URL {
        paths.trainingURL.appendingPathComponent(
            ".checkpoint-discard-cleanup.\(cleanupID.uuidString).\(suffix)",
            isDirectory: suffix == "checkpoints"
        )
    }

    private func assertDurableCleanupStateUnchanged(
        _ fixture: CompletedCleanupFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            try Data(contentsOf: fixture.context.paths.outputSplatURL),
            fixture.outputBytes,
            file: file,
            line: line
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.context.paths.trainingManifestURL),
            fixture.manifestBytes,
            file: file,
            line: line
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.retainedDatasetURL),
            fixture.retainedDatasetBytes,
            file: file,
            line: line
        )
    }

    private func assertCompletedCleanupConverged(
        _ fixture: CompletedCleanupFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.context.paths.msplatCheckpointURL.path),
            file: file,
            line: line
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.context.paths.msplatOutputURL.deletingLastPathComponent().path
            ),
            file: file,
            line: line
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.context.paths.completedTrainingCleanupJournalURL.path
            ),
            file: file,
            line: line
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: fixture.context.paths.trainingURL.path)
                .contains(where: { $0.hasPrefix(".completed-training-cleanup.") }),
            file: file,
            line: line
        )
        try assertDurableCleanupStateUnchanged(fixture, file: file, line: line)
    }
}

private enum CleanupCrash: Error {
    case injected
}

private final class CleanupCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

private struct CompletedCleanupFixture {
    let context: ArtifactStoreTestContext
    let publication: ValidatedPublishedResult
    let outputBytes: Data
    let manifestBytes: Data
    let retainedDatasetURL: URL
    let retainedDatasetBytes: Data
}

private struct ArtifactStoreTestContext {
    let root: URL
    let paths: ProjectPaths
    let metadata: ProjectMetadata

    func cleanup() {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }
}
