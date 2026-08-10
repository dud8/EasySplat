import Darwin
import Foundation
import XCTest
@testable import EasySplatCore

final class PublishedResultPublisherAuthorityTests: XCTestCase {
    func testResolveRejectsTrainingManifestReplacedDuringPlyValidation() throws {
        let fixture = try makeFixture(named: "ResolveManifestRace")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }

        _ = try PublishedResultPublisher.publishCompletedTraining(
            metadata: fixture.metadata,
            resolvedRunPlan: fixture.plan,
            geometry: fixture.geometry,
            paths: fixture.paths,
            publicationID: fixture.publicationID,
            publishedAt: fixture.publishedAt
        )

        var replacement = try TrainingArtifactStore.loadManifest(
            from: fixture.paths.trainingManifestURL,
            projectPaths: fixture.paths
        )
        replacement.elapsedSeconds = try XCTUnwrap(replacement.elapsedSeconds) + 1
        let replacementData = try TrainingArtifactStore.encodedManifestData(
            replacement,
            projectPaths: fixture.paths
        )
        let replacementURL = fixture.paths.trainingURL.appendingPathComponent(
            ".replacement-training-manifest.json"
        )
        try replacementData.write(to: replacementURL, options: [.atomic])

        let mutation = PublisherAuthorityMutation()
        var operations = PublishedResultPairOperations.system()
        operations.willValidatePly = { name in
            guard name == "splat.ply" else { return }
            mutation.capture {
                guard Darwin.rename(
                    replacementURL.path,
                    fixture.paths.trainingManifestURL.path
                ) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }

        let resolved = try PublishedResultPublisher.resolveCompletedTraining(
            metadata: fixture.metadata,
            resolvedRunPlan: fixture.plan,
            paths: fixture.paths,
            pairOperations: operations
        )

        XCTAssertNil(resolved)
        XCTAssertNoThrow(try mutation.result())
        XCTAssertEqual(mutation.attemptCount, 1)
        XCTAssertEqual(
            try TrainingArtifactStore.loadManifest(
                from: fixture.paths.trainingManifestURL,
                projectPaths: fixture.paths
            ),
            replacement
        )
    }

    func testResolveRejectsCanonicalGeometryDifferentFromPublishedLineage() throws {
        let fixture = try makeFixture(named: "ResolveGeometryReplacement")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }

        _ = try PublishedResultPublisher.publishCompletedTraining(
            metadata: fixture.metadata,
            resolvedRunPlan: fixture.plan,
            geometry: fixture.geometry,
            paths: fixture.paths,
            publicationID: fixture.publicationID,
            publishedAt: fixture.publishedAt
        )
        var replacement = fixture.geometry
        replacement.peakMemoryBytes += 1
        try encodeGeometry(replacement).write(
            to: fixture.paths.geometryManifestURL,
            options: [.atomic]
        )

        XCTAssertNil(try PublishedResultPublisher.resolveCompletedTraining(
            metadata: fixture.metadata,
            resolvedRunPlan: fixture.plan,
            paths: fixture.paths
        ))
    }

    func testPublishRejectsTrainingManifestThatReplacedValidatedDerivation() throws {
        let fixture = try makeFixture(named: "PublishManifestDerivationRace")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let original = try TrainingArtifactStore.loadManifest(
            from: fixture.paths.trainingManifestURL,
            projectPaths: fixture.paths
        )
        var replacement = original
        replacement.inputDigest = String(repeating: "7", count: 64)
        replacement.datasetDerivation.datasetInputDigest = replacement.inputDigest
        let replacementData = try TrainingArtifactStore.encodedManifestData(
            replacement,
            projectPaths: fixture.paths
        )
        try replacementData.write(
            to: fixture.paths.trainingManifestURL,
            options: [.atomic]
        )

        XCTAssertThrowsError(try PublishedResultPublisher.publishCompletedTraining(
            metadata: fixture.metadata,
            resolvedRunPlan: fixture.plan,
            geometry: fixture.geometry,
            paths: fixture.paths,
            publicationID: fixture.publicationID,
            publishedAt: fixture.publishedAt,
            expectedDatasetDerivation: original.datasetDerivation
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.outputSplatURL.path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.outputSplatReceiptURL.path
        ))
    }

    func testPublishRejectsMovedOrReplacedCanonicalGeometryBeforePairCommit() throws {
        enum Mutation: CaseIterable {
            case moved
            case replaced
            case reencoded
        }

        for mutationKind in Mutation.allCases {
            let fixture = try makeFixture(named: "PublishGeometryRace-\(mutationKind)")
            defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }

            let geometryDirectory = fixture.paths.geometryManifestURL
                .deletingLastPathComponent()
            let displacedURL = geometryDirectory.appendingPathComponent(
                ".displaced-geometry-manifest.json"
            )
            let replacementURL = geometryDirectory.appendingPathComponent(
                ".replacement-geometry-manifest.json"
            )
            func prepareReplacement(
                _ data: Data,
                geometry: GeometryArtifact
            ) throws {
                try data.write(to: replacementURL, options: [.atomic])
                XCTAssertEqual(
                    try GeometryArtifactStore.loadManifest(
                        from: replacementURL,
                        projectPaths: fixture.paths
                    ),
                    geometry
                )
            }
            switch mutationKind {
            case .moved:
                break
            case .replaced:
                var replacementGeometry = fixture.geometry
                replacementGeometry.peakMemoryBytes += 1
                try prepareReplacement(
                    encodeGeometry(replacementGeometry),
                    geometry: replacementGeometry
                )
            case .reencoded:
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let replacementData = try encoder.encode(fixture.geometry)
                XCTAssertNotEqual(
                    replacementData,
                    try Data(contentsOf: fixture.paths.geometryManifestURL)
                )
                try prepareReplacement(replacementData, geometry: fixture.geometry)
            }

            let mutation = PublisherAuthorityMutation()
            let plyValidations = PublisherAuthorityCounter()
            var operations = PublishedResultPairOperations.system()
            operations.willValidatePly = { name in
                if name == "splat.ply" {
                    plyValidations.increment()
                }
            }

            XCTAssertThrowsError(try PublishedResultPublisher.publishCompletedTraining(
                metadata: fixture.metadata,
                resolvedRunPlan: fixture.plan,
                geometry: fixture.geometry,
                paths: fixture.paths,
                publicationID: fixture.publicationID,
                publishedAt: fixture.publishedAt,
                pairOperations: operations,
                beforePublish: {
                    mutation.capture {
                        switch mutationKind {
                        case .moved:
                            try FileManager.default.moveItem(
                                at: fixture.paths.geometryManifestURL,
                                to: displacedURL
                            )
                        case .replaced, .reencoded:
                            guard Darwin.rename(
                                replacementURL.path,
                                fixture.paths.geometryManifestURL.path
                            ) == 0 else {
                                throw POSIXError(
                                    POSIXErrorCode(rawValue: errno) ?? .EIO
                                )
                            }
                        }
                    }
                }
            ), "Mutation: \(mutationKind)")

            XCTAssertNoThrow(try mutation.result(), "Mutation: \(mutationKind)")
            XCTAssertEqual(mutation.attemptCount, 1, "Mutation: \(mutationKind)")
            XCTAssertEqual(plyValidations.value, 1, "Mutation: \(mutationKind)")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: fixture.paths.outputSplatURL.path),
                "Mutation: \(mutationKind)"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.paths.outputSplatReceiptURL.path
                ),
                "Mutation: \(mutationKind)"
            )
            XCTAssertEqual(
                try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
                .unavailable(.missingPair),
                "Mutation: \(mutationKind)"
            )
        }
    }

    func testPublishRejectsGeometryReplacementAfterPlyStaging() throws {
        let fixture = try makeFixture(named: "PublishStagedGeometryRace")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let geometryDirectory = fixture.paths.geometryManifestURL
            .deletingLastPathComponent()
        let replacementURL = geometryDirectory.appendingPathComponent(
            ".replacement-geometry-manifest.json"
        )
        var replacement = fixture.geometry
        replacement.peakMemoryBytes += 1
        try encodeGeometry(replacement).write(to: replacementURL, options: [.atomic])

        let mutation = PublisherAuthorityMutation()
        var operations = PublishedResultPairOperations.system()
        operations.didReachCheckpoint = { checkpoint in
            guard checkpoint == .newPlyDurable else { return }
            mutation.capture {
                guard Darwin.rename(
                    replacementURL.path,
                    fixture.paths.geometryManifestURL.path
                ) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }

        XCTAssertThrowsError(try PublishedResultPublisher.publishCompletedTraining(
            metadata: fixture.metadata,
            resolvedRunPlan: fixture.plan,
            geometry: fixture.geometry,
            paths: fixture.paths,
            publicationID: fixture.publicationID,
            publishedAt: fixture.publishedAt,
            pairOperations: operations
        ))
        XCTAssertNoThrow(try mutation.result())
        XCTAssertEqual(mutation.attemptCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.outputSplatURL.path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.outputSplatReceiptURL.path
        ))
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .unavailable(.missingPair)
        )
    }

    func testManifestPersistenceRejectsByteIdenticalReplacementAfterPairCommit() throws {
        let fixture = try makeFixture(named: "ManifestCASBoundIdentity")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let originalManifest = try Data(contentsOf: fixture.paths.trainingManifestURL)
        var originalStatus = stat()
        XCTAssertEqual(lstat(fixture.paths.trainingManifestURL.path, &originalStatus), 0)

        let replacementURL = fixture.paths.trainingURL.appendingPathComponent(
            ".byte-identical-training-manifest.json"
        )
        try originalManifest.write(to: replacementURL, options: [.withoutOverwriting])
        XCTAssertEqual(chmod(replacementURL.path, mode_t(0o600)), 0)
        var replacementStatus = stat()
        XCTAssertEqual(lstat(replacementURL.path, &replacementStatus), 0)
        XCTAssertNotEqual(replacementStatus.st_ino, originalStatus.st_ino)

        let mutation = PublisherAuthorityMutation()
        XCTAssertThrowsError(try PublishedResultPublisher.publishCompletedTraining(
            metadata: fixture.metadata,
            resolvedRunPlan: fixture.plan,
            geometry: fixture.geometry,
            paths: fixture.paths,
            publicationID: fixture.publicationID,
            publishedAt: fixture.publishedAt,
            persistPreparedManifest: {
                data, artifact, evidence, expectedSourceIdentity, paths in
                mutation.capture {
                    guard Darwin.rename(
                        replacementURL.path,
                        paths.trainingManifestURL.path
                    ) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
                try mutation.result()
                try TrainingArtifactStore.persistPreparedManifest(
                    data,
                    artifact: artifact,
                    validatedOutputEvidence: evidence,
                    expectedSourceIdentity: expectedSourceIdentity,
                    paths: paths
                )
            }
        ))
        XCTAssertNoThrow(try mutation.result())
        XCTAssertEqual(mutation.attemptCount, 1)

        var survivingStatus = stat()
        XCTAssertEqual(lstat(fixture.paths.trainingManifestURL.path, &survivingStatus), 0)
        XCTAssertEqual(survivingStatus.st_ino, replacementStatus.st_ino)
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.trainingManifestURL),
            originalManifest
        )
        guard case .available(let committed) = try PublishedResultPairStore.resolve(
            projectPaths: fixture.paths
        ) else {
            return XCTFail("The authority-conferring receipt should remain committed")
        }
        XCTAssertEqual(committed.receipt.publicationID, fixture.publicationID)

        let adopted = try PublishedResultPublisher.publishCompletedTraining(
            metadata: fixture.metadata,
            resolvedRunPlan: fixture.plan,
            geometry: fixture.geometry,
            paths: fixture.paths,
            publicationID: fixture.publicationID,
            publishedAt: fixture.publishedAt
        )
        XCTAssertEqual(adopted.receipt.publicationID, fixture.publicationID)
        XCTAssertEqual(
            try TrainingArtifactStore.loadManifest(
                from: fixture.paths.trainingManifestURL,
                projectPaths: fixture.paths
            ).outputPath,
            PublishedSplatReceipt.canonicalOutputPath
        )
    }

    func testBoundPublishRejectsInitialRootReplacementWithoutMutatingEitherTree() throws {
        let fixture = try makeFixture(named: "BoundPublishRootReplacement")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let originalSnapshot = try PublisherDirectorySnapshot.capture(
            root: fixture.paths.root
        )
        let rootDescriptor = try openProjectRootDescriptor(fixture.paths.root)
        defer { Darwin.close(rootDescriptor) }

        let displacedRoot = fixture.cleanupRoot.appendingPathComponent(
            "leased-original.easysplatproj",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: fixture.paths.root,
            to: displacedRoot
        )
        try FileManager.default.copyItem(
            at: displacedRoot,
            to: fixture.paths.root
        )
        let replacementSnapshot = try PublisherDirectorySnapshot.capture(
            root: fixture.paths.root
        )
        XCTAssertEqual(replacementSnapshot, originalSnapshot)
        let displacedSnapshot = try PublisherDirectorySnapshot.capture(
            root: displacedRoot
        )
        XCTAssertEqual(displacedSnapshot, originalSnapshot)
        let checkpoints = PublisherCheckpointRecorder()
        var operations = PublishedResultPairOperations.system()
        operations.didReachCheckpoint = { checkpoints.record($0) }

        XCTAssertThrowsError(try PublishedResultPublisher.publishCompletedTraining(
            metadata: fixture.metadata,
            resolvedRunPlan: fixture.plan,
            geometry: fixture.geometry,
            paths: fixture.paths,
            projectRootDescriptor: rootDescriptor,
            publicationID: fixture.publicationID,
            publishedAt: fixture.publishedAt,
            pairOperations: operations
        )) { error in
            XCTAssertEqual(error as? PublishedResultPairError, .unsafeOutput)
        }

        XCTAssertEqual(
            checkpoints.values,
            [],
            "A replaced root must fail before lock acquisition or transaction work"
        )
        XCTAssertEqual(
            try PublisherDirectorySnapshot.capture(root: fixture.paths.root),
            replacementSnapshot,
            "The copied pathname replacement must remain byte-for-byte untouched"
        )
        XCTAssertEqual(
            try PublisherDirectorySnapshot.capture(root: displacedRoot),
            displacedSnapshot,
            "Initial root mismatch must fail before mutating the leased tree"
        )
    }

    func testPostReceiptCommitRootReplacementFinishesLeasedPairBeforeFailingClosed() throws {
        let fixture = try makeFixture(named: "PostReceiptCommitRootReplacement")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let rootDescriptor = try openProjectRootDescriptor(fixture.paths.root)
        defer { Darwin.close(rootDescriptor) }
        let originalSnapshot = try PublisherDirectorySnapshot.capture(
            root: fixture.paths.root
        )
        let replacementRoot = fixture.cleanupRoot.appendingPathComponent(
            "postcommit-replacement.easysplatproj",
            isDirectory: true
        )
        let displacedRoot = fixture.cleanupRoot.appendingPathComponent(
            "postcommit-leased.easysplatproj",
            isDirectory: true
        )
        try FileManager.default.copyItem(
            at: fixture.paths.root,
            to: replacementRoot
        )
        let replacementSnapshot = try PublisherDirectorySnapshot.capture(
            root: replacementRoot
        )
        XCTAssertEqual(replacementSnapshot, originalSnapshot)

        let rootSwap = PublisherAuthorityMutation()
        let checkpoints = PublisherCheckpointRecorder()
        var operations = PublishedResultPairOperations.system()
        operations.didReachCheckpoint = { checkpoint in
            checkpoints.record(checkpoint)
            // PairStore emits this only after the receipt and receipt-committed
            // journal are durable. Swapping here deterministically exercises the
            // non-cancellable consistency boundary before its next path check.
            guard checkpoint == .newReceiptInstalled else { return }
            rootSwap.capture {
                try FileManager.default.moveItem(
                    at: fixture.paths.root,
                    to: displacedRoot
                )
                try FileManager.default.moveItem(
                    at: replacementRoot,
                    to: fixture.paths.root
                )
            }
        }

        XCTAssertThrowsError(try PublishedResultPublisher.publishCompletedTraining(
            metadata: fixture.metadata,
            resolvedRunPlan: fixture.plan,
            geometry: fixture.geometry,
            paths: fixture.paths,
            projectRootDescriptor: rootDescriptor,
            publicationID: fixture.publicationID,
            publishedAt: fixture.publishedAt,
            pairOperations: operations
        )) { error in
            XCTAssertEqual(
                error as? PublishedResultPairError,
                .publicationConflict(
                    "the publication lock or Output directory changed"
                )
            )
        }

        XCTAssertNoThrow(try rootSwap.result())
        XCTAssertEqual(rootSwap.attemptCount, 1)
        XCTAssertTrue(checkpoints.values.contains(.newReceiptInstalled))
        XCTAssertTrue(
            checkpoints.values.contains(.transactionRetired),
            "The descriptor-bound recovery must retire the committed transaction"
        )
        XCTAssertEqual(
            try PublisherDirectorySnapshot.capture(root: fixture.paths.root),
            replacementSnapshot,
            "No lock, pair, or rebound manifest may be written to the replacement"
        )

        let displacedPaths = ProjectPaths(root: displacedRoot)
        let outputNames = try FileManager.default.contentsOfDirectory(
            atPath: displacedPaths.outputURL.path
        )
        XCTAssertFalse(outputNames.contains {
            $0.hasPrefix(".published-result-tx-")
                || $0.hasPrefix(".published-result-build-")
                || $0.hasPrefix(".published-result-retired-")
        })
        XCTAssertEqual(
            try TrainingArtifactStore.loadManifest(
                from: displacedPaths.trainingManifestURL,
                projectPaths: displacedPaths
            ).outputPath,
            PublishedSplatReceipt.canonicalOutputPath,
            "Receipt authority must be matched by its rebound manifest before root mismatch surfaces"
        )
        let committed = try XCTUnwrap(
            PublishedResultPublisher.resolveCompletedTraining(
                metadata: fixture.metadata,
                resolvedRunPlan: fixture.plan,
                paths: displacedPaths,
                projectRootDescriptor: rootDescriptor
            ),
            "The displaced leased tree must retain one exact manifest-bound pair"
        )
        XCTAssertEqual(committed.receipt.publicationID, fixture.publicationID)
        XCTAssertEqual(
            try Data(contentsOf: displacedPaths.outputSplatURL),
            try Data(contentsOf: displacedPaths.msplatOutputURL)
        )
    }
}

private extension PublishedResultPublisherAuthorityTests {
    struct Fixture {
        let cleanupRoot: URL
        let paths: ProjectPaths
        let metadata: ProjectMetadata
        let plan: ResolvedRunPlan
        let geometry: GeometryArtifact
        let publicationID: UUID
        let publishedAt: Date
    }

    func makeFixture(named name: String) throws -> Fixture {
        let cleanupRoot = try TestFileBuilder.makeTempDir()
        let root = cleanupRoot.appendingPathComponent(
            "\(name).easysplatproj",
            isDirectory: true
        )
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()

        let requested = RequestedRunOptions(
            capturePath: .orbit,
            detailProfile: .balanced,
            cameraGrouping: .sameCameraAndLens,
            lensProjection: .perspective,
            inputOrdering: .automatic,
            resourcePolicy: .maximumPerformance,
            photoSelection: .useAllValidPhotos
        )
        var plan = RunPlanResolver.resolve(
            requestedOptions: requested,
            input: .photos(folder: "Originals/Photos"),
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: .none
        )
        plan.trainerIterationLimit = 30_000

        let publicationID = UUID(
            uuidString: "91A7A7B2-1BC9-43D2-A438-64F5EE5CF0C4"
        )!
        var metadata = ProjectMetadata(
            id: UUID(uuidString: "9877FE00-5A9C-43A0-AB0D-FD4DABAA86B8")!,
            title: "Publisher authority fixture",
            input: .photos(folder: "Originals/Photos"),
            requestedRunOptions: requested,
            resolvedRunPlan: plan,
            stageTimings: [
                StageTimingRecord(
                    stage: .trainSplat,
                    startedAt: Date(timeIntervalSince1970: 1_767_224_800),
                    durationSeconds: 812.5
                ),
                StageTimingRecord(
                    stage: .exportSplat,
                    startedAt: Date(timeIntervalSince1970: 1_767_225_700),
                    durationSeconds: 0.75
                ),
            ]
        )
        metadata.pendingPublicationID = publicationID

        var geometry = makeGeometryArtifact()
        geometry.selectedFramesDigest = String(repeating: "e", count: 64)
        geometry.residualProvenance = "colmap-text-tracks-v1"
        try encodeGeometry(geometry).write(
            to: paths.geometryManifestURL,
            options: [.atomic]
        )
        let geometryManifestSHA256 = try GeometryArtifactStore.manifestDigest(
            matching: geometry,
            at: paths.geometryManifestURL
        )

        try TestFileBuilder.writeMinimalPly(at: paths.msplatOutputURL, vertexCount: 7)
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(
            at: paths.msplatOutputURL
        )
        var training = makeTrainingArtifact(outputPath: "Training/msplat/splat.ply")
        training.detailProfile = requested.detailProfile
        training.iterationLimit = plan.trainerIterationLimit
        training.plateauWindow = plan.plateauWindow
        training.cameraOrderSeed = plan.runSeed
        training.completedIteration = plan.trainerIterationLimit
        training.memoryBudgetBytes = min(
            training.memoryBudgetBytes,
            plan.trainerMemoryBudgetBytes
        )
        training.resourceAdmission = makeTestTrainingResourceAdmission(
            resourcePolicy: requested.resourcePolicy
        )
        training.outputSHA256 = evidence.sha256
        training.outputBytes = Int64(evidence.byteCount)
        training.gaussianCount = evidence.vertexCount
        training.sceneBounds = evidence.sceneBounds
        training.geometryDigest = String(repeating: "d", count: 64)
        training.datasetDerivation = makeMsplatDatasetDerivation(
            inputDigest: training.inputDigest,
            geometryDigest: training.geometryDigest,
            registeredImageNames: geometry.orderedImageNames,
            sourceGeometryManifestSHA256: geometryManifestSHA256,
            sourceSelectedFramesDigest: geometry.selectedFramesDigest,
            maximumImageDimension: plan.maximumImageDimension
        )
        XCTAssertEqual(
            training.geometryDigest,
            training.datasetDerivation.datasetGeometryDigest
        )
        XCTAssertNotEqual(
            training.datasetDerivation.datasetGeometryDigest,
            training.datasetDerivation.sourceGeometryManifestSHA256
        )
        try TrainingArtifactStore.persist(training, paths: paths)

        return Fixture(
            cleanupRoot: cleanupRoot,
            paths: paths,
            metadata: metadata,
            plan: plan,
            geometry: geometry,
            publicationID: publicationID,
            publishedAt: Date(timeIntervalSince1970: 1_767_225_800)
        )
    }

    func encodeGeometry(_ geometry: GeometryArtifact) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(geometry)
    }

    func openProjectRootDescriptor(_ root: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return descriptor
    }
}

private struct PublisherDirectorySnapshot: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        enum Kind: String, Equatable, Sendable {
            case directory
            case regularFile
            case symbolicLink
        }

        let kind: Kind
        let permissions: mode_t
        let contents: Data?
    }

    let rootPermissions: mode_t
    let entries: [String: Entry]

    static func capture(root: URL) throws -> PublisherDirectorySnapshot {
        var rootStatus = stat()
        guard Darwin.lstat(root.path, &rootStatus) == 0,
              (rootStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let names = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .sorted()
        var entries: [String: Entry] = [:]
        for name in names {
            let url = root.appendingPathComponent(name)
            var status = stat()
            guard Darwin.lstat(url.path, &status) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let kind: Entry.Kind
            let contents: Data?
            switch status.st_mode & S_IFMT {
            case S_IFDIR:
                kind = .directory
                contents = nil
            case S_IFREG:
                kind = .regularFile
                contents = try Data(contentsOf: url)
            case S_IFLNK:
                kind = .symbolicLink
                contents = try FileManager.default.destinationOfSymbolicLink(
                    atPath: url.path
                ).data(using: .utf8)
            default:
                throw CocoaError(.fileReadUnknown)
            }
            entries[name] = Entry(
                kind: kind,
                permissions: status.st_mode & 0o7777,
                contents: contents
            )
        }
        return PublisherDirectorySnapshot(
            rootPermissions: rootStatus.st_mode & 0o7777,
            entries: entries
        )
    }
}

private final class PublisherAuthorityMutation: @unchecked Sendable {
    private let lock = NSLock()
    private var capturedResult: Result<Void, Error>?
    private var attempts = 0

    var attemptCount: Int { lock.withLock { attempts } }

    func capture(_ operation: () throws -> Void) {
        lock.withLock {
            attempts += 1
            guard capturedResult == nil else { return }
            capturedResult = Result { try operation() }
        }
    }

    func result() throws {
        try lock.withLock {
            try XCTUnwrap(capturedResult).get()
        }
    }
}

private final class PublisherCheckpointRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [PublishedResultPairCheckpoint] = []

    var values: [PublishedResultPairCheckpoint] { lock.withLock { storage } }

    func record(_ checkpoint: PublishedResultPairCheckpoint) {
        lock.withLock { storage.append(checkpoint) }
    }
}

private final class PublisherAuthorityCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}
