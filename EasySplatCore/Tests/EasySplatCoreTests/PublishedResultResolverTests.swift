import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import EasySplatCore

final class PublishedResultResolverTests: XCTestCase {
    func testReceiptBoundFinishedProjectResolvesCurrent() throws {
        let fixture = try makeFixture(named: "ReceiptBoundCurrent")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }

        let operations = operations(for: fixture)
        let resolution = try PublishedResultResolver.resolve(
            projectURL: fixture.paths.root,
            operations: operations
        )

        guard case .current(.receiptBound(let current)) = resolution else {
            return XCTFail("Expected a receipt-bound current result, got \(resolution)")
        }
        XCTAssertEqual(current.publishedResult.receipt, fixture.receipt)
        XCTAssertEqual(current.publishedResult.outputEvidence, fixture.outputEvidence)
        XCTAssertEqual(current.snapshot.geometryArtifact, fixture.geometry)
        XCTAssertEqual(current.snapshot.trainingArtifact, fixture.training)
        XCTAssertEqual(current.liveProject.title, fixture.metadata.title)
        XCTAssertEqual(current.presentation, fixture.receipt.presentation)
    }

    func testReceiptBindingKeepsManifestAndSparseGeometryDigestsDistinct() throws {
        let fixture = try makeFixture(named: "DistinctGeometryDigests")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }

        XCTAssertEqual(
            fixture.geometryManifestDigest,
            fixture.training.datasetDerivation.sourceGeometryManifestSHA256
        )
        XCTAssertNotEqual(
            fixture.geometryManifestDigest,
            fixture.training.geometryDigest
        )
        XCTAssertEqual(
            fixture.receipt.lineage.trainingGeometryDigest,
            fixture.training.geometryDigest
        )

        guard case .current(.receiptBound) = try PublishedResultResolver.resolve(
            projectURL: fixture.paths.root,
            operations: operations(for: fixture)
        ) else {
            return XCTFail("Expected distinct manifest and sparse digests to resolve")
        }
    }

    func testReceiptBindingUsesAuthenticatedGeometryManifestDigest() throws {
        let fixture = try makeFixture(named: "AuthenticatedGeometryManifestDigest")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }

        var operations = operations(for: fixture)
        operations.loadReceiptBoundSnapshot = { _, evidence in
            guard evidence == fixture.outputEvidence else {
                throw ResolverTestError.wrongOutputEvidence
            }
            return ReceiptBoundProjectSnapshot(
                snapshot: fixture.snapshot,
                trainingManifestData: fixture.trainingManifestData,
                geometryManifestDigest: String(repeating: "f", count: 64)
            )
        }

        XCTAssertEqual(
            try PublishedResultResolver.resolve(
                projectURL: fixture.paths.root,
                operations: operations
            ),
            .unavailable(.bindingMismatch)
        )
    }

    func testFailedRetrainResolvesPreviousWithoutReadingCurrentArtifacts() throws {
        var fixture = try makeFixture(named: "FailedPrevious")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        fixture.metadata.state = PipelineState(
            stage: .trainSplat,
            lastError: "The retrain failed."
        )
        fixture.metadata.lastFailureAt = Date(timeIntervalSince1970: 2_100)
        fixture.metadata.pendingPublicationID = UUID()

        var operations = operations(for: fixture)
        operations.loadReceiptBoundSnapshot = { _, _ in
            throw ResolverTestError.unexpectedCurrentArtifactRead
        }

        let resolution = try PublishedResultResolver.resolve(
            projectURL: fixture.paths.root,
            operations: operations
        )

        guard case .previous(let previous) = resolution else {
            return XCTFail("Expected the validated previous result, got \(resolution)")
        }
        XCTAssertEqual(previous.publishedResult.receipt, fixture.receipt)
        XCTAssertEqual(previous.liveProject.projectID, fixture.metadata.id)
        XCTAssertEqual(previous.liveProject.title, fixture.metadata.title)
    }

    func testInterruptedRetrainResolvesPrevious() throws {
        var fixture = try makeFixture(named: "InterruptedPrevious")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        fixture.metadata.state = PipelineState(stage: .sfmMapping, lastError: nil)
        fixture.metadata.lastRunStartedAt = Date(timeIntervalSince1970: 2_200)
        fixture.metadata.pendingPublicationID = UUID()

        let resolution = try PublishedResultResolver.resolve(
            projectURL: fixture.paths.root,
            operations: operations(for: fixture)
        )

        guard case .previous(let previous) = resolution else {
            return XCTFail("Expected an interrupted previous result, got \(resolution)")
        }
        XCTAssertEqual(previous.publishedResult.receipt.publicationID, fixture.publicationID)
    }

    func testFailedProjectWithBarePlyIsUnavailable() throws {
        var fixture = try makeFixture(named: "BarePlyFailed", writeReceipt: false)
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        fixture.metadata.state = PipelineState(stage: .trainSplat, lastError: "Failed")
        fixture.metadata.pendingPublicationID = UUID()

        var operations = operations(for: fixture)
        operations.loadLegacySnapshot = { _ in
            throw ResolverTestError.unexpectedLegacyArtifactRead
        }

        XCTAssertEqual(
            try PublishedResultResolver.resolve(
                projectURL: fixture.paths.root,
                operations: operations
            ),
            .unavailable(.latestAttemptNotViewable)
        )
    }

    func testFinishedLegacyProjectWithoutReceiptResolvesCurrentOnlyAfterFullValidation() throws {
        let fixture = try makeFixture(named: "LegacyCurrent", writeReceipt: false)
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let calls = ResolverCounter()

        var operations = operations(for: fixture)
        operations.loadLegacySnapshot = { _ in
            calls.increment()
            return fixture.snapshot
        }

        let resolution = try PublishedResultResolver.resolve(
            projectURL: fixture.paths.root,
            operations: operations
        )

        guard case .current(.legacy(let legacy)) = resolution else {
            return XCTFail("Expected a validated legacy current result, got \(resolution)")
        }
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(legacy.outputURL, fixture.paths.outputSplatURL)
        XCTAssertEqual(legacy.snapshot.trainingArtifact, fixture.training)
        XCTAssertEqual(legacy.liveProject.title, fixture.metadata.title)
    }

    func testGroupReadableLegacyPlyCannotOpenOrReceiveAuthority() throws {
        let fixture = try makePersistedFixture(named: "GroupReadableLegacy")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        try FileManager.default.removeItem(at: fixture.paths.outputSplatReceiptURL)
        XCTAssertEqual(Darwin.chmod(fixture.paths.outputSplatURL.path, 0o640), 0)
        let metadataBefore = try Data(contentsOf: fixture.paths.metadataURL)
        let outputBefore = try Data(contentsOf: fixture.paths.outputSplatURL)

        XCTAssertEqual(
            try PublishedResultResolver.resolve(
                projectURL: fixture.paths.root,
                operations: .system()
            ),
            .unavailable(.invalidPublishedResult)
        )
        XCTAssertThrowsError(
            try PublishedResultResolver.preserveCurrentResultForRetraining(
                projectURL: fixture.paths.root
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.outputSplatReceiptURL.path
            )
        )
        XCTAssertEqual(try Data(contentsOf: fixture.paths.metadataURL), metadataBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.outputSplatURL), outputBefore)
    }

    func testReadOnlyOutputWithoutPublicationLockIsUnavailableInsteadOfThrowing() throws {
        let fixture = try makeFixture(named: "ReadOnlyOutput")
        defer {
            _ = Darwin.chmod(fixture.paths.outputURL.path, 0o700)
            try? FileManager.default.removeItem(at: fixture.cleanupRoot)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.publishedResultLockURL.path
            )
        )
        XCTAssertEqual(Darwin.chmod(fixture.paths.outputURL.path, 0o500), 0)

        XCTAssertEqual(
            try PublishedResultResolver.resolve(
                projectURL: fixture.paths.root,
                operations: operations(for: fixture)
            ),
            .unavailable(.invalidPublishedResult)
        )
    }

    func testLegacyCurrentRejectsStructuralValidationFailure() throws {
        let fixture = try makeFixture(named: "LegacyValidationFailure", writeReceipt: false)
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }

        var operations = operations(for: fixture)
        operations.loadLegacySnapshot = { _ in
            throw ProjectArtifactSnapshotError.invalidFinishedTraining
        }

        XCTAssertEqual(
            try PublishedResultResolver.resolve(
                projectURL: fixture.paths.root,
                operations: operations
            ),
            .unavailable(.currentProjectInvalid)
        )
    }

    func testMalformedReceiptBlocksLegacyFallback() throws {
        let fixture = try makeFixture(named: "MalformedReceipt")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        try writeReceiptData(Data("{".utf8), paths: fixture.paths)

        var operations = operations(for: fixture)
        operations.loadLegacySnapshot = { _ in
            throw ResolverTestError.unexpectedLegacyArtifactRead
        }

        XCTAssertEqual(
            try PublishedResultResolver.resolve(
                projectURL: fixture.paths.root,
                operations: operations
            ),
            .unavailable(.invalidPublishedResult)
        )
    }

    func testRejectedMalformedReceiptCannotBecomeLegacyIfItDisappears() throws {
        let fixture = try makeFixture(named: "MalformedReceiptRemoval")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        try writeReceiptData(Data("{".utf8), paths: fixture.paths)
        let legacyCalls = ResolverCounter()

        var operations = operations(for: fixture)
        operations.authorizePair = { _, _, _, _ in
            try FileManager.default.removeItem(
                at: fixture.paths.outputSplatReceiptURL
            )
            throw PublishedResultPairError.publicationConflict(
                "the rejected receipt disappeared"
            )
        }
        operations.loadLegacySnapshot = { _ in
            legacyCalls.increment()
            throw ResolverTestError.unexpectedLegacyArtifactRead
        }

        XCTAssertEqual(
            try PublishedResultResolver.resolve(
                projectURL: fixture.paths.root,
                operations: operations
            ),
            .unavailable(.invalidPublishedResult)
        )
        XCTAssertEqual(legacyCalls.value, 0)
    }

    func testReceiptAppearanceAndDisappearanceDuringAuthorizationBlocksLegacyFallback() throws {
        let fixture = try makeFixture(
            named: "TransientFutureReceipt",
            writeReceipt: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let legacyCalls = ResolverCounter()

        var operations = operations(for: fixture)
        operations.authorizePair = { _, _, _, _ in
            let future = Data(#"{"schemaVersion":2,"future":"transient"}"#.utf8)
            try future.write(
                to: fixture.paths.outputSplatReceiptURL,
                options: [.atomic]
            )
            try FileManager.default.removeItem(
                at: fixture.paths.outputSplatReceiptURL
            )
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 123)],
                ofItemAtPath: fixture.paths.outputURL.path
            )
            throw PublishedResultPairError.publicationConflict(
                "a future receipt appeared and disappeared"
            )
        }
        operations.loadLegacySnapshot = { _ in
            legacyCalls.increment()
            return fixture.snapshot
        }

        XCTAssertEqual(
            try PublishedResultResolver.resolve(
                projectURL: fixture.paths.root,
                operations: operations
            ),
            .unavailable(.invalidPublishedResult)
        )
        XCTAssertEqual(legacyCalls.value, 0)
    }

    func testFutureReceiptBlocksLegacyFallbackAndRemainsUntouched() throws {
        let fixture = try makeFixture(named: "FutureReceipt")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let future = Data(#"{"schemaVersion":2,"future":"untouched"}"#.utf8)
        try writeReceiptData(future, paths: fixture.paths)

        let resolution = try PublishedResultResolver.resolve(
            projectURL: fixture.paths.root,
            operations: operations(for: fixture)
        )

        XCTAssertEqual(resolution, .unavailable(.invalidPublishedResult))
        XCTAssertEqual(try Data(contentsOf: fixture.paths.outputSplatReceiptURL), future)
    }

    func testTamperedPlyIsUnavailable() throws {
        let fixture = try makeFixture(named: "TamperedPly")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        try TestFileBuilder.writeMinimalPly(
            at: fixture.paths.outputSplatURL,
            vertexCount: fixture.outputEvidence.vertexCount + 1
        )
        XCTAssertEqual(Darwin.chmod(fixture.paths.outputSplatURL.path, 0o600), 0)

        XCTAssertEqual(
            try PublishedResultResolver.resolve(
                projectURL: fixture.paths.root,
                operations: operations(for: fixture)
            ),
            .unavailable(.invalidPublishedResult)
        )
    }

    func testReceiptProjectUUIDMismatchIsUnavailable() throws {
        var fixture = try makeFixture(named: "ProjectMismatch")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        fixture.receipt = replacing(
            fixture.receipt,
            projectID: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!
        )
        try writeReceipt(fixture.receipt, paths: fixture.paths)

        XCTAssertEqual(
            try PublishedResultResolver.resolve(
                projectURL: fixture.paths.root,
                operations: operations(for: fixture)
            ),
            .unavailable(.projectMismatch)
        )
    }

    func testCurrentTrainingManifestMismatchIsUnavailable() throws {
        var fixture = try makeFixture(named: "ManifestMismatch")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        fixture.receipt = replacing(
            fixture.receipt,
            lineage: PublishedSplatLineage(
                trainingManifestSHA256: String(repeating: "9", count: 64),
                trainingInputDigest: fixture.receipt.lineage.trainingInputDigest,
                trainingGeometryDigest: fixture.receipt.lineage.trainingGeometryDigest
            )
        )
        try writeReceipt(fixture.receipt, paths: fixture.paths)

        XCTAssertEqual(
            try PublishedResultResolver.resolve(
                projectURL: fixture.paths.root,
                operations: operations(for: fixture)
            ),
            .unavailable(.bindingMismatch)
        )
    }

    func testCurrentGeometryPresentationMismatchIsUnavailable() throws {
        var fixture = try makeFixture(named: "GeometryMismatch")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let original = fixture.receipt.presentation.reconstruction
        let replacement = PublishedReconstructionSummary(
            registeredViewCount: original.registeredViewCount,
            totalViewCount: original.totalViewCount,
            pointCount: original.pointCount + 1,
            observationCount: original.observationCount,
            medianPixelResidual: original.medianPixelResidual,
            p90PixelResidual: original.p90PixelResidual,
            solverVersion: original.solverVersion,
            modelVersion: original.modelVersion,
            cameraModel: original.cameraModel,
            residualProvenance: original.residualProvenance,
            usedPartialCoverageAcceptance: original.usedPartialCoverageAcceptance,
            secondLargestModelRegisteredViewCount:
                original.secondLargestModelRegisteredViewCount
        )
        fixture.receipt = replacing(fixture.receipt, reconstruction: replacement)
        try writeReceipt(fixture.receipt, paths: fixture.paths)

        XCTAssertEqual(
            try PublishedResultResolver.resolve(
                projectURL: fixture.paths.root,
                operations: operations(for: fixture)
            ),
            .unavailable(.bindingMismatch)
        )
    }

    func testLatestMetadataChangeDuringDecisionRetriesIntoPreviousResult() throws {
        let fixture = try makeFixture(named: "MetadataRace")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        var failed = fixture.metadata
        failed.state = PipelineState(stage: .trainSplat, lastError: "Retrain failed")
        failed.pendingPublicationID = UUID()
        failed.lastFailureAt = Date(timeIntervalSince1970: 2_300)
        let sequence = ResolverMetadataSequence([
            fixture.metadata,
            failed,
            failed,
            failed,
        ])
        let snapshotCalls = ResolverCounter()

        var operations = operations(for: fixture)
        operations.loadMetadata = { _ in try sequence.next() }
        operations.loadReceiptBoundSnapshot = { _, _ in
            snapshotCalls.increment()
            return fixture.receiptBoundSnapshot
        }

        let resolution = try PublishedResultResolver.resolve(
            projectURL: fixture.paths.root,
            operations: operations
        )

        guard case .previous(let previous) = resolution else {
            return XCTFail("Expected the stable failed-attempt decision, got \(resolution)")
        }
        XCTAssertEqual(snapshotCalls.value, 1)
        XCTAssertEqual(previous.liveProject.projectID, failed.id)
    }

    func testPairConflictIsUnavailableAndDoesNotAttemptLegacyValidation() throws {
        let fixture = try makeFixture(named: "PairConflict")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let legacyCalls = ResolverCounter()
        let conflictingTransaction = fixture.paths.outputURL.appendingPathComponent(
            ".published-result-tx-foreign",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: conflictingTransaction,
            withIntermediateDirectories: false
        )
        let sentinel = conflictingTransaction.appendingPathComponent("foreign")
        try Data("preserve".utf8).write(to: sentinel)

        var operations = operations(for: fixture)
        operations.authorizePair = { _, _, _, _ in
            throw PublishedResultPairError.publicationConflict("pending transaction")
        }
        operations.loadLegacySnapshot = { _ in
            legacyCalls.increment()
            throw ResolverTestError.unexpectedLegacyArtifactRead
        }

        XCTAssertEqual(
            try PublishedResultResolver.resolve(
                projectURL: fixture.paths.root,
                operations: operations
            ),
            .unavailable(.publicationConflict)
        )
        XCTAssertEqual(legacyCalls.value, 0)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("preserve".utf8))
    }

    func testCleanupWrappedPublicationAuthorityBlocksLegacyFallback() throws {
        let fixture = try makeFixture(
            named: "CleanupWrappedAuthority",
            writeReceipt: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let legacyCalls = ResolverCounter()
        let quarantined = fixture.paths.outputURL.appendingPathComponent(
            ".cleanup-.published-result-tx-foreign",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: quarantined,
            withIntermediateDirectories: false
        )

        var operations = operations(for: fixture)
        operations.authorizePair = { _, _, _, _ in
            throw PublishedResultPairError.publicationConflict(
                "quarantined publication authority"
            )
        }
        operations.loadLegacySnapshot = { _ in
            legacyCalls.increment()
            return fixture.snapshot
        }

        XCTAssertEqual(
            try PublishedResultResolver.resolve(
                projectURL: fixture.paths.root,
                operations: operations
            ),
            .unavailable(.publicationConflict)
        )
        XCTAssertEqual(legacyCalls.value, 0)
    }

    func testFilesystemAliasedPublicationNamespacesBlockLegacyFallback() throws {
        let reservedAliases = [
            ".PUBLISHED-RESULT-TX-foreign",
            ".CLEANUP-.PUBLISHED-RECEIPT-BUILD-AUTHORITY-foreign",
        ]

        for (index, reservedAlias) in reservedAliases.enumerated() {
            let fixture = try makeFixture(
                named: "AliasedPublicationNamespace-\(index)",
                writeReceipt: false
            )
            defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
            let legacyCalls = ResolverCounter()
            try FileManager.default.createDirectory(
                at: fixture.paths.outputURL.appendingPathComponent(
                    reservedAlias,
                    isDirectory: true
                ),
                withIntermediateDirectories: false
            )

            var operations = operations(for: fixture)
            operations.authorizePair = { _, _, _, _ in
                throw PublishedResultPairError.publicationConflict(
                    "case-aliased publication authority"
                )
            }
            operations.loadLegacySnapshot = { _ in
                legacyCalls.increment()
                return fixture.snapshot
            }

            XCTAssertEqual(
                try PublishedResultResolver.resolve(
                    projectURL: fixture.paths.root,
                    operations: operations
                ),
                .unavailable(.publicationConflict),
                reservedAlias
            )
            XCTAssertEqual(legacyCalls.value, 0, reservedAlias)
        }
    }

    func testPairEvaluationMetadataIOFailurePropagates() throws {
        let fixture = try makeFixture(named: "MetadataEIO")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }

        var operations = operations(for: fixture)
        operations.loadMetadata = { _ in throw POSIXError(.EIO) }

        XCTAssertThrowsError(
            try PublishedResultResolver.resolve(
                projectURL: fixture.paths.root,
                operations: operations
            )
        ) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EIO)
        }
    }

    func testPairEvaluationSnapshotDescriptorExhaustionPropagates() throws {
        let fixture = try makeFixture(named: "SnapshotEMFILE")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }

        var operations = operations(for: fixture)
        operations.loadReceiptBoundSnapshot = { _, _ in
            throw POSIXError(.EMFILE)
        }

        XCTAssertThrowsError(
            try PublishedResultResolver.resolve(
                projectURL: fixture.paths.root,
                operations: operations
            )
        ) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EMFILE)
        }
    }

    func testPairAuthorizationSystemFailurePropagates() throws {
        let fixture = try makeFixture(named: "AuthorizationEIO")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }

        var operations = operations(for: fixture)
        operations.authorizePair = { _, _, _, _ in throw POSIXError(.EIO) }

        XCTAssertThrowsError(
            try PublishedResultResolver.resolve(
                projectURL: fixture.paths.root,
                operations: operations
            )
        ) { error in
            XCTAssertEqual((error as? POSIXError)?.code, .EIO)
        }
    }

    func testReceiptBoundDecisionValidatesPlyExactlyOnce() throws {
        let fixture = try makeFixture(named: "OnePlyHash")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let validations = ResolverCounter()

        var operations = operations(for: fixture)
        operations.pairOperations.willValidatePly = { leaf in
            if leaf == "splat.ply" { validations.increment() }
        }

        guard case .current(.receiptBound) = try PublishedResultResolver.resolve(
            projectURL: fixture.paths.root,
            operations: operations
        ) else {
            return XCTFail("Expected a receipt-bound current result")
        }
        XCTAssertEqual(validations.value, 1)
    }

    func testPersistedCurrentProjectUsesRealMetadataAndReceiptBoundSnapshotLoaders() throws {
        let fixture = try makePersistedFixture(named: "PersistedCurrent")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let validations = ResolverCounter()

        var operations = PublishedResultResolverOperations.system()
        operations.didBeginPlyEvidenceValidation = { leaf in
            if leaf == fixture.paths.outputSplatURL.lastPathComponent {
                validations.increment()
            }
        }

        let resolution = try PublishedResultResolver.resolve(
            projectURL: fixture.paths.root,
            operations: operations
        )

        guard case .current(.receiptBound(let current)) = resolution else {
            return XCTFail("Expected a real receipt-bound current result, got \(resolution)")
        }
        XCTAssertEqual(current.publishedResult.receipt, fixture.receipt)
        XCTAssertEqual(current.snapshot.metadata.pendingPublicationID, nil)
        XCTAssertEqual(current.snapshot.geometryArtifact, fixture.geometry)
        XCTAssertEqual(current.snapshot.trainingArtifact, fixture.training)
        XCTAssertEqual(validations.value, 1)
    }

    func testRealLoaderHashesAuthenticatedGeometryManifestExactlyOnce() throws {
        let fixture = try makePersistedFixture(named: "OneGeometryManifestHash")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let hashes = ResolverCounter()
        var loadOperations = ReceiptBoundSnapshotLoadOperations.system()
        let systemHash = loadOperations.geometryManifestSHA256
        loadOperations.geometryManifestSHA256 = { data in
            hashes.increment()
            return systemHash(data)
        }

        let snapshot = try ProjectArtifactSnapshotStore.loadReceiptBoundFull(
            projectURL: fixture.paths.root,
            outputEvidence: fixture.outputEvidence,
            operations: loadOperations
        )

        XCTAssertEqual(hashes.value, 1)
        XCTAssertEqual(
            snapshot.geometryManifestDigest,
            fixture.geometryManifestDigest
        )
    }

    func testResolverHasNoUnobservedPathBasedGeometryManifestHash() throws {
        let source = try resolverSource()

        XCTAssertFalse(
            source.contains("GeometryArtifactStore.manifestDigest"),
            "Resolver geometry-manifest hashing must use the observable bound-byte seam."
        )
    }

    func testRealLoaderRejectsGeometryManifestReplacementAfterValidation() throws {
        let fixture = try makePersistedFixture(named: "GeometryManifestReplacement")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let original = try Data(contentsOf: fixture.paths.geometryManifestURL)
        var loadOperations = ReceiptBoundSnapshotLoadOperations.system()
        loadOperations.afterGeometryManifestValidation = {
            var replacement = original
            replacement.append(0x0A)
            try replacement.write(
                to: fixture.paths.geometryManifestURL,
                options: [.atomic]
            )
        }

        XCTAssertThrowsError(
            try ProjectArtifactSnapshotStore.loadReceiptBoundFull(
                projectURL: fixture.paths.root,
                outputEvidence: fixture.outputEvidence,
                operations: loadOperations
            )
        ) { error in
            XCTAssertEqual(
                error as? GeometryArtifactStore.Error,
                .artifactDigestMismatch("geometry manifest")
            )
        }
    }

    func testResolverHasNoUnobservedDirectPlyEvidenceValidation() throws {
        let source = try resolverSource()

        XCTAssertFalse(
            source.contains("ProjectArtifactValidator.validatedPlyEvidence"),
            "Resolver PLY validation must route through the observable pair authorization seam."
        )
    }

    func testPersistedLegacyCurrentUsesRealMetadataAndFullSnapshotLoader() throws {
        let fixture = try makePersistedFixture(named: "PersistedLegacyCurrent")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        try FileManager.default.removeItem(
            at: fixture.paths.outputSplatReceiptURL
        )

        let resolution = try PublishedResultResolver.resolve(
            projectURL: fixture.paths.root,
            operations: .system()
        )

        guard case .current(.legacy(let current)) = resolution else {
            return XCTFail("Expected a real legacy current result, got \(resolution)")
        }
        XCTAssertEqual(current.snapshot.metadata.pendingPublicationID, nil)
        XCTAssertEqual(current.snapshot.geometryArtifact, fixture.geometry)
        XCTAssertEqual(current.snapshot.trainingArtifact, fixture.training)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fixture.paths.publishedResultLockURL.path
        )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
    }

    func testUnsafePreexistingPublicationLockBlocksLegacyFallback() throws {
        let fixture = try makeFixture(
            named: "UnsafeLegacyLock",
            writeReceipt: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let outside = fixture.cleanupRoot.appendingPathComponent("outside-lock")
        try Data("preserve".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.publishedResultLockURL,
            withDestinationURL: outside
        )

        XCTAssertEqual(
            try PublishedResultResolver.resolve(
                projectURL: fixture.paths.root,
                operations: operations(for: fixture)
            ),
            .unavailable(.invalidPublishedResult)
        )
        XCTAssertEqual(try Data(contentsOf: outside), Data("preserve".utf8))
    }

    func testTitleNotesAndViewerPreferencesComeFromFinalStableMetadataRead() throws {
        let fixture = try makeFixture(named: "LiveMetadata")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        var edited = fixture.metadata
        edited.title = "Edited title"
        edited.notes = "Edited notes"
        edited.viewerPreferences = ViewerPreferences(isUprightFlipActive: true)
        let sequence = ResolverMetadataSequence([fixture.metadata, edited])

        var operations = operations(for: fixture)
        operations.loadMetadata = { _ in try sequence.next() }

        let resolution = try PublishedResultResolver.resolve(
            projectURL: fixture.paths.root,
            operations: operations
        )

        guard case .current(.receiptBound(let current)) = resolution else {
            return XCTFail("Expected a receipt-bound current result, got \(resolution)")
        }
        XCTAssertEqual(current.liveProject.title, "Edited title")
        XCTAssertEqual(current.liveProject.notes, "Edited notes")
        XCTAssertEqual(
            current.liveProject.viewerPreferences,
            ViewerPreferences(isUprightFlipActive: true)
        )
        XCTAssertEqual(current.snapshot.metadata.title, "Edited title")
    }

    func testPreviousPresentationKeepsReceiptEraTimingWithoutResamplingLatestAttempt() throws {
        var fixture = try makeFixture(named: "ReceiptEraTiming")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        fixture.metadata.state = PipelineState(stage: .trainSplat, lastError: "Failed")
        fixture.metadata.pendingPublicationID = UUID()
        fixture.metadata.createToViewerReadySeconds = 999
        fixture.metadata.stageTimings = [
            StageTimingRecord(
                stage: .trainSplat,
                startedAt: Date(timeIntervalSince1970: 2_500),
                durationSeconds: 8
            ),
        ]

        let resolution = try PublishedResultResolver.resolve(
            projectURL: fixture.paths.root,
            operations: operations(for: fixture)
        )

        guard case .previous(let previous) = resolution else {
            return XCTFail("Expected a previous result, got \(resolution)")
        }
        XCTAssertEqual(
            previous.presentation.createToViewerReadySeconds,
            fixture.receipt.presentation.createToViewerReadySeconds
        )
        XCTAssertEqual(
            previous.presentation.stageTimings,
            fixture.receipt.presentation.stageTimings
        )
        XCTAssertNotEqual(
            previous.presentation.createToViewerReadySeconds,
            fixture.metadata.createToViewerReadySeconds
        )
    }

    func testPreviousResultUsesLiveNotesAndPreferencesWithoutExposingInputPaths() throws {
        var fixture = try makeFixture(named: "PreviousLiveFields")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let externalPath = "/Users/private/Captures/secret.mov"
        fixture.metadata.input = .video(files: [externalPath])
        fixture.metadata.title = "Renamed after failure"
        fixture.metadata.notes = "Keep this note live"
        fixture.metadata.viewerPreferences = ViewerPreferences(
            isUprightFlipActive: true
        )
        fixture.metadata.state = PipelineState(
            stage: .trainSplat,
            lastError: "Retrain failed"
        )
        fixture.metadata.pendingPublicationID = UUID()

        let resolution = try PublishedResultResolver.resolve(
            projectURL: fixture.paths.root,
            operations: operations(for: fixture)
        )

        guard case .previous(let previous) = resolution else {
            return XCTFail("Expected a previous result, got \(resolution)")
        }
        XCTAssertEqual(previous.liveProject.title, "Renamed after failure")
        XCTAssertEqual(previous.liveProject.notes, "Keep this note live")
        XCTAssertEqual(
            previous.liveProject.viewerPreferences,
            ViewerPreferences(isUprightFlipActive: true)
        )
        XCTAssertFalse(String(reflecting: previous).contains(externalPath))
    }

    func testLegacyInitialMetadataUnreadabilityReturnsCurrentProjectInvalid() throws {
        let fixture = try makeFixture(
            named: "LegacyUnreadableInitialMetadata",
            writeReceipt: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }

        var operations = operations(for: fixture)
        operations.loadMetadata = { _ in
            throw CocoaError(.fileReadNoSuchFile)
        }

        XCTAssertEqual(
            try PublishedResultResolver.resolve(
                projectURL: fixture.paths.root,
                operations: operations
            ),
            .unavailable(.currentProjectInvalid)
        )
    }

    func testLegacyMetadataDisappearanceAfterSnapshotReturnsProjectChanged() throws {
        let fixture = try makeFixture(
            named: "LegacyMetadataDisappears",
            writeReceipt: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let reads = ResolverMetadataReadPlan([
            .value(fixture.metadata),
            .missing,
        ])

        var operations = operations(for: fixture)
        operations.loadMetadata = { _ in try reads.next() }

        XCTAssertEqual(
            try PublishedResultResolver.resolve(
                projectURL: fixture.paths.root,
                operations: operations
            ),
            .unavailable(.projectChanged)
        )
    }

    func testLegacyNonviewableMetadataDisappearanceReturnsProjectChanged() throws {
        var fixture = try makeFixture(
            named: "LegacyFailedMetadataDisappears",
            writeReceipt: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        fixture.metadata.state = PipelineState(
            stage: .trainSplat,
            lastError: "Failed"
        )
        fixture.metadata.pendingPublicationID = UUID()
        let reads = ResolverMetadataReadPlan([
            .value(fixture.metadata),
            .missing,
        ])

        var operations = operations(for: fixture)
        operations.loadMetadata = { _ in try reads.next() }

        XCTAssertEqual(
            try PublishedResultResolver.resolve(
                projectURL: fixture.paths.root,
                operations: operations
            ),
            .unavailable(.projectChanged)
        )
    }

    func testLegacyMetadataInstabilityExhaustsBoundedAttempts() throws {
        let fixture = try makeFixture(
            named: "LegacyMetadataInstability",
            writeReceipt: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        var changed = fixture.metadata
        changed.stageTimings = [
            StageTimingRecord(
                stage: .trainSplat,
                startedAt: Date(timeIntervalSince1970: 1_500),
                durationSeconds: 13
            ),
        ]
        let reads = ResolverMetadataReadPlan([
            .value(fixture.metadata), .value(changed),
            .value(fixture.metadata), .value(changed),
            .value(fixture.metadata), .value(changed),
        ])

        var operations = operations(for: fixture)
        operations.loadMetadata = { _ in try reads.next() }

        XCTAssertEqual(
            try PublishedResultResolver.resolve(
                projectURL: fixture.paths.root,
                operations: operations
            ),
            .unavailable(.projectChanged)
        )
        XCTAssertEqual(reads.readCount, 6)
    }

    func testLegacyMetadataCancellationPropagates() throws {
        let fixture = try makeFixture(
            named: "LegacyMetadataCancellation",
            writeReceipt: false
        )
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }

        var operations = operations(for: fixture)
        operations.loadMetadata = { _ in throw CancellationError() }

        XCTAssertThrowsError(
            try PublishedResultResolver.resolve(
                projectURL: fixture.paths.root,
                operations: operations
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testPreserveCurrentResultBackfillsLegacyReceiptWithoutReplacingPly() throws {
        let fixture = try makePersistedFixture(named: "LegacyBackfill")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        try FileManager.default.removeItem(at: fixture.paths.outputSplatReceiptURL)

        var before = stat()
        XCTAssertEqual(Darwin.lstat(fixture.paths.outputSplatURL.path, &before), 0)
        let beforeMetadata = try Data(contentsOf: fixture.paths.metadataURL)
        let publicationID = UUID(
            uuidString: "FD80C9D2-B1B2-42A5-A665-6457437612A3"
        )!

        let result = try PublishedResultResolver
            .preserveCurrentResultForRetraining(
                projectURL: fixture.paths.root,
                publicationID: publicationID,
                publishedAt: Date(timeIntervalSince1970: 3_000)
            )

        var after = stat()
        XCTAssertEqual(Darwin.lstat(fixture.paths.outputSplatURL.path, &after), 0)
        XCTAssertEqual(after.st_dev, before.st_dev)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(after.st_size, before.st_size)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.metadataURL), beforeMetadata)
        XCTAssertEqual(result.receipt.publicationID, publicationID)
        XCTAssertEqual(result.outputEvidence, fixture.outputEvidence)
        XCTAssertEqual(
            try PublishedSplatReceiptStore.load(projectPaths: fixture.paths),
            result.receipt
        )
        guard case .current(.receiptBound(let resolved)) =
                try PublishedResultResolver.resolve(projectURL: fixture.paths.root)
        else {
            return XCTFail("Expected the backfilled project to resolve current")
        }
        XCTAssertEqual(resolved.publishedResult.receipt, result.receipt)
    }

    func testLegacyBackfillReturnsCanonicalReceiptForLivePublicationDate() throws {
        let fixture = try makePersistedFixture(named: "LiveDateBackfill")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        try FileManager.default.removeItem(at: fixture.paths.outputSplatReceiptURL)

        let result = try PublishedResultResolver
            .preserveCurrentResultForRetraining(
                projectURL: fixture.paths.root
            )
        let committedData = try Data(
            contentsOf: fixture.paths.outputSplatReceiptURL
        )
        let committedReceipt = try PublishedSplatReceiptStore.decode(
            committedData
        )

        XCTAssertEqual(result.receipt, committedReceipt)
        XCTAssertEqual(
            try PublishedSplatReceiptStore.encode(result.receipt),
            committedData
        )
        guard case .current(.receiptBound(let resolved)) =
                try PublishedResultResolver.resolve(projectURL: fixture.paths.root)
        else {
            return XCTFail("Expected canonical live-date authority")
        }
        XCTAssertEqual(resolved.publishedResult.receipt, committedReceipt)
    }

    func testLegacyBackfillValidatesThePlyExactlyOnce() throws {
        let fixture = try makePersistedFixture(named: "SingleHashLegacyBackfill")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        try FileManager.default.removeItem(at: fixture.paths.outputSplatReceiptURL)
        let validations = ResolverCounter()
        var operations = PublishedResultPairOperations.system()
        operations.willValidatePly = { _ in validations.increment() }

        _ = try PublishedResultResolver.preserveCurrentResultForRetraining(
            projectURL: fixture.paths.root,
            pairOperations: operations
        )

        XCTAssertEqual(validations.value, 1)
    }

    func testLegacyBackfillRecoversValidatedStagedReceiptAfterProcessDeath() throws {
        for suffix in [".json", ".json.pending"] {
            let fixture = try makePersistedFixture(
                named: "RecoverLegacyBackfill-\(suffix)"
            )
            defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
            let receipt = try PublishedSplatReceiptStore.load(
                projectPaths: fixture.paths
            )
            let receiptData = try Data(
                contentsOf: fixture.paths.outputSplatReceiptURL
            )
            try FileManager.default.removeItem(
                at: fixture.paths.outputSplatReceiptURL
            )
            let stagedURL = fixture.paths.outputURL.appendingPathComponent(
                ".published-result-backfill-"
                    + receipt.publicationID.uuidString.lowercased()
                    + suffix
            )
            try receiptData.write(to: stagedURL)
            XCTAssertEqual(Darwin.chmod(stagedURL.path, 0o600), 0)

            let recovered = try PublishedResultResolver
                .preserveCurrentResultForRetraining(
                    projectURL: fixture.paths.root,
                    publicationID: UUID(),
                    publishedAt: Date(timeIntervalSince1970: 9_999)
                )

            XCTAssertEqual(recovered.receipt, receipt, suffix)
            XCTAssertEqual(
                try Data(contentsOf: fixture.paths.outputSplatReceiptURL),
                receiptData,
                suffix
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: stagedURL.path),
                suffix
            )
        }
    }

    func testLegacyBackfillPreservesMalformedResidueAsConflict() throws {
        let fixture = try makePersistedFixture(named: "MalformedBackfillResidue")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        try FileManager.default.removeItem(at: fixture.paths.outputSplatReceiptURL)
        let stagedURL = fixture.paths.outputURL.appendingPathComponent(
            ".published-result-backfill-"
                + UUID().uuidString.lowercased()
                + ".json"
        )
        try Data("not a receipt".utf8).write(to: stagedURL)
        XCTAssertEqual(Darwin.chmod(stagedURL.path, 0o600), 0)

        XCTAssertThrowsError(
            try PublishedResultResolver.preserveCurrentResultForRetraining(
                projectURL: fixture.paths.root
            )
        ) { error in
            guard case PublishedResultPairError.publicationConflict = error else {
                return XCTFail("Expected preserved publication conflict, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.outputSplatReceiptURL.path
            )
        )
    }

    func testLegacyBackfillPreservesDuplicateResiduesAsConflict() throws {
        let fixture = try makePersistedFixture(named: "DuplicateBackfillResidues")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let receipt = try PublishedSplatReceiptStore.load(projectPaths: fixture.paths)
        try FileManager.default.removeItem(at: fixture.paths.outputSplatReceiptURL)
        let first = try writeBackfillResidue(
            receipt,
            paths: fixture.paths,
            suffix: ".json"
        )
        let second = try writeBackfillResidue(
            receipt,
            paths: fixture.paths,
            suffix: ".json.pending"
        )

        XCTAssertThrowsError(
            try PublishedResultResolver.preserveCurrentResultForRetraining(
                projectURL: fixture.paths.root
            )
        ) { error in
            guard case PublishedResultPairError.publicationConflict = error else {
                return XCTFail("Expected duplicate-residue conflict, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.outputSplatReceiptURL.path
            )
        )
    }

    func testLegacyBackfillPreservesValidReceiptForWrongProjectAsConflict() throws {
        let fixture = try makePersistedFixture(named: "WrongProjectBackfillResidue")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let receipt = replacing(fixture.receipt, projectID: UUID())
        try FileManager.default.removeItem(at: fixture.paths.outputSplatReceiptURL)
        let staged = try writeBackfillResidue(receipt, paths: fixture.paths)

        XCTAssertThrowsError(
            try PublishedResultResolver.preserveCurrentResultForRetraining(
                projectURL: fixture.paths.root
            )
        ) { error in
            guard case PublishedResultPairError.publicationConflict = error else {
                return XCTFail("Expected wrong-project conflict, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.outputSplatReceiptURL.path
            )
        )
    }

    func testLegacyBackfillRollbackRestoresRecoveredStage() throws {
        let fixture = try makePersistedFixture(named: "RecoveredBackfillRollback")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let receiptData = try Data(contentsOf: fixture.paths.outputSplatReceiptURL)
        try FileManager.default.removeItem(at: fixture.paths.outputSplatReceiptURL)
        let staged = try writeBackfillResidue(fixture.receipt, paths: fixture.paths)

        var operations = PublishedResultPairOperations.system()
        let systemSync = operations.synchronizeDirectory
        let syncs = ResolverCounter()
        operations.synchronizeDirectory = { descriptor in
            syncs.increment()
            if syncs.value == 1 {
                errno = ENOSPC
                return -1
            }
            return systemSync(descriptor)
        }

        XCTAssertThrowsError(
            try PublishedResultResolver.preserveCurrentResultForRetraining(
                projectURL: fixture.paths.root,
                pairOperations: operations
            )
        ) { error in
            guard case PublishedResultPairError.persistence = error else {
                return XCTFail("Expected the injected persistence failure, got \(error)")
            }
        }
        XCTAssertGreaterThanOrEqual(syncs.value, 2)
        XCTAssertEqual(try Data(contentsOf: staged), receiptData)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.outputSplatReceiptURL.path
            )
        )
    }

    func testLegacyBackfillCancellationPreservesRecoveredResidue() throws {
        let fixture = try makePersistedFixture(named: "RecoveredBackfillCancellation")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        _ = try PublishedResultResolver.resolve(projectURL: fixture.paths.root)
        let receiptData = try Data(contentsOf: fixture.paths.outputSplatReceiptURL)
        try FileManager.default.removeItem(at: fixture.paths.outputSplatReceiptURL)
        _ = try writeBackfillResidue(
            fixture.receipt,
            paths: fixture.paths,
            suffix: ".json.pending"
        )

        var operations = PublishedResultPairOperations.system()
        let systemSync = operations.synchronizeFile
        let syncs = ResolverCounter()
        operations.synchronizeFile = { descriptor in
            let result = systemSync(descriptor)
            if result == 0 { syncs.increment() }
            return result
        }

        XCTAssertThrowsError(
            try PublishedResultResolver.preserveCurrentResultForRetraining(
                projectURL: fixture.paths.root,
                pairOperations: operations,
                shouldCancel: { syncs.value > 0 }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        let residues = try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.outputURL.path
        ).filter { $0.hasPrefix(".published-result-backfill-") }
        XCTAssertEqual(residues.count, 1)
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.outputURL.appendingPathComponent(residues[0])),
            receiptData
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.outputSplatReceiptURL.path
            )
        )
    }

    func testLegacyBackfillRejectsLinkedResidueWithoutFollowingIt() throws {
        let fixture = try makePersistedFixture(named: "LinkedBackfillResidue")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let receiptData = try Data(contentsOf: fixture.paths.outputSplatReceiptURL)
        try FileManager.default.removeItem(at: fixture.paths.outputSplatReceiptURL)
        let outside = fixture.cleanupRoot.appendingPathComponent("outside-receipt.json")
        try receiptData.write(to: outside)
        let staged = fixture.paths.outputURL.appendingPathComponent(
            ".published-result-backfill-"
                + fixture.receipt.publicationID.uuidString.lowercased()
                + ".json"
        )
        try FileManager.default.createSymbolicLink(
            atPath: staged.path,
            withDestinationPath: outside.path
        )

        XCTAssertThrowsError(
            try PublishedResultResolver.preserveCurrentResultForRetraining(
                projectURL: fixture.paths.root
            )
        ) { error in
            guard case PublishedResultPairError.publicationConflict = error else {
                return XCTFail("Expected linked-residue conflict, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: outside), receiptData)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: staged.path),
            outside.path
        )
    }

    func testPreserveCurrentResultReturnsExistingFailedRetrainAuthority() throws {
        var fixture = try makePersistedFixture(named: "ExistingPrevious")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        fixture.metadata.state = PipelineState(
            stage: .trainSplat,
            lastError: "The retrain failed."
        )
        fixture.metadata.lastFailureAt = Date(timeIntervalSince1970: 3_100)
        fixture.metadata.pendingPublicationID = UUID()
        try ProjectMetadataStore.save(
            fixture.metadata,
            to: fixture.paths.metadataURL
        )
        let beforeReceipt = try Data(
            contentsOf: fixture.paths.outputSplatReceiptURL
        )

        var operations = PublishedResultPairOperations.system()
        operations.synchronizeFile = { _ in
            errno = ENOSPC
            return -1
        }
        let result = try PublishedResultResolver
            .preserveCurrentResultForRetraining(
                projectURL: fixture.paths.root,
                pairOperations: operations
            )

        XCTAssertEqual(result.receipt.publicationID, fixture.publicationID)
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.outputSplatReceiptURL),
            beforeReceipt
        )
    }

    func testPreserveUsesInjectedPairOperationsForInitialAuthorityResolution() throws {
        let fixture = try makePersistedFixture(named: "InjectedPreserveOperations")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let validations = ResolverCounter()
        var operations = PublishedResultPairOperations.system()
        operations.willValidatePly = { _ in validations.increment() }

        let result = try PublishedResultResolver
            .preserveCurrentResultForRetraining(
                projectURL: fixture.paths.root,
                pairOperations: operations
            )

        XCTAssertEqual(result.receipt.publicationID, fixture.publicationID)
        XCTAssertEqual(validations.value, 1)
    }

    func testPreserveCustomCancellationAppliesDuringInitialAuthorityResolution() throws {
        let fixture = try makePersistedFixture(named: "InjectedPreserveCancellation")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        let checks = ResolverCounter()

        XCTAssertThrowsError(
            try PublishedResultResolver.preserveCurrentResultForRetraining(
                projectURL: fixture.paths.root,
                shouldCancel: {
                    checks.increment()
                    return checks.value >= 2
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertGreaterThanOrEqual(checks.value, 2)
    }

    func testPreserveCurrentResultRejectsFailedBarePlyWithoutCreatingReceipt() throws {
        var fixture = try makePersistedFixture(named: "FailedBareBackfill")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        try FileManager.default.removeItem(at: fixture.paths.outputSplatReceiptURL)
        fixture.metadata.state = PipelineState(
            stage: .trainSplat,
            lastError: "The retrain failed."
        )
        fixture.metadata.lastFailureAt = Date(timeIntervalSince1970: 3_200)
        fixture.metadata.pendingPublicationID = UUID()
        try ProjectMetadataStore.save(
            fixture.metadata,
            to: fixture.paths.metadataURL
        )
        let beforePly = try Data(contentsOf: fixture.paths.outputSplatURL)

        XCTAssertThrowsError(
            try PublishedResultResolver.preserveCurrentResultForRetraining(
                projectURL: fixture.paths.root
            )
        ) { error in
            XCTAssertEqual(
                error as? PublishedResultPreservationError,
                .currentResultUnavailable
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.outputSplatReceiptURL.path
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.outputSplatURL),
            beforePly
        )
    }

    func testLegacyBackfillPersistenceFailureLeavesMetadataAndPlyUnchanged() throws {
        let fixture = try makePersistedFixture(named: "BackfillDiskFull")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        try FileManager.default.removeItem(at: fixture.paths.outputSplatReceiptURL)
        let beforeMetadata = try Data(contentsOf: fixture.paths.metadataURL)
        let beforePly = try Data(contentsOf: fixture.paths.outputSplatURL)
        var before = stat()
        XCTAssertEqual(Darwin.lstat(fixture.paths.outputSplatURL.path, &before), 0)

        var operations = PublishedResultPairOperations.system()
        operations.synchronizeFile = { _ in
            errno = ENOSPC
            return -1
        }
        XCTAssertThrowsError(
            try PublishedResultResolver.preserveCurrentResultForRetraining(
                projectURL: fixture.paths.root,
                pairOperations: operations
            )
        )

        var after = stat()
        XCTAssertEqual(Darwin.lstat(fixture.paths.outputSplatURL.path, &after), 0)
        XCTAssertEqual(after.st_dev, before.st_dev)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.outputSplatURL), beforePly)
        XCTAssertEqual(try Data(contentsOf: fixture.paths.metadataURL), beforeMetadata)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.outputSplatReceiptURL.path
            )
        )
    }

    func testLegacyBackfillCancellationLeavesNoReceipt() throws {
        let fixture = try makePersistedFixture(named: "BackfillCancellation")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        try FileManager.default.removeItem(at: fixture.paths.outputSplatReceiptURL)

        XCTAssertThrowsError(
            try PublishedResultResolver.preserveCurrentResultForRetraining(
                projectURL: fixture.paths.root,
                shouldCancel: { true }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.paths.outputSplatReceiptURL.path
            )
        )
    }

    func testQuickPreviousResultHintRequiresLatestAttemptFailure() throws {
        var fixture = try makePersistedFixture(named: "QuickHintFailed")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }

        XCTAssertFalse(PublishedResultResolver.hasQuickPreviousResultHint(
            projectURL: fixture.paths.root,
            metadata: fixture.metadata
        ))

        fixture.metadata.state = PipelineState(
            stage: .trainSplat,
            lastError: "The retrain failed."
        )
        fixture.metadata.lastFailureAt = Date(timeIntervalSince1970: 3_500)
        fixture.metadata.pendingPublicationID = UUID()
        try ProjectMetadataStore.save(
            fixture.metadata,
            to: fixture.paths.metadataURL
        )

        XCTAssertTrue(PublishedResultResolver.hasQuickPreviousResultHint(
            projectURL: fixture.paths.root,
            metadata: fixture.metadata
        ))
    }

    func testQuickPreviousResultHintRejectsBareAndMalformedReceipts() throws {
        var fixture = try makePersistedFixture(named: "QuickHintReceipt")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        fixture.metadata.state = PipelineState(
            stage: .trainSplat,
            lastError: "Failed"
        )
        fixture.metadata.pendingPublicationID = UUID()

        try FileManager.default.removeItem(
            at: fixture.paths.outputSplatReceiptURL
        )
        XCTAssertFalse(PublishedResultResolver.hasQuickPreviousResultHint(
            projectURL: fixture.paths.root,
            metadata: fixture.metadata
        ))

        try Data("{not-json".utf8).write(
            to: fixture.paths.outputSplatReceiptURL
        )
        XCTAssertFalse(PublishedResultResolver.hasQuickPreviousResultHint(
            projectURL: fixture.paths.root,
            metadata: fixture.metadata
        ))
    }

    func testQuickPreviousResultHintRejectsFutureReceiptSchema() throws {
        var fixture = try makePersistedFixture(named: "QuickHintFuture")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        fixture.metadata.state = PipelineState(
            stage: .trainSplat,
            lastError: "Failed"
        )
        fixture.metadata.pendingPublicationID = UUID()
        let receiptData = try Data(
            contentsOf: fixture.paths.outputSplatReceiptURL
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: receiptData) as? [String: Any]
        )
        object["schemaVersion"] = PublishedSplatReceipt.currentSchemaVersion + 1
        try JSONSerialization.data(withJSONObject: object).write(
            to: fixture.paths.outputSplatReceiptURL
        )

        XCTAssertFalse(PublishedResultResolver.hasQuickPreviousResultHint(
            projectURL: fixture.paths.root,
            metadata: fixture.metadata
        ))
    }

    func testQuickPreviousResultHintRejectsLinkedOutput() throws {
        var fixture = try makePersistedFixture(named: "QuickHintHardlink")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        fixture.metadata.state = PipelineState(
            stage: .trainSplat,
            lastError: "Failed"
        )
        fixture.metadata.pendingPublicationID = UUID()
        let alias = fixture.cleanupRoot.appendingPathComponent("splat-alias.ply")
        XCTAssertEqual(
            Darwin.link(
                fixture.paths.outputSplatURL.path,
                alias.path
            ),
            0
        )

        XCTAssertFalse(PublishedResultResolver.hasQuickPreviousResultHint(
            projectURL: fixture.paths.root,
            metadata: fixture.metadata
        ))
    }

    func testQuickPreviousResultHintRejectsSymlinkOutput() throws {
        var fixture = try makePersistedFixture(named: "QuickHintSymlink")
        defer { try? FileManager.default.removeItem(at: fixture.cleanupRoot) }
        fixture.metadata.state = PipelineState(
            stage: .trainSplat,
            lastError: "Failed"
        )
        fixture.metadata.pendingPublicationID = UUID()
        let outside = fixture.cleanupRoot.appendingPathComponent("outside.ply")
        try FileManager.default.copyItem(
            at: fixture.paths.outputSplatURL,
            to: outside
        )
        try FileManager.default.removeItem(at: fixture.paths.outputSplatURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.outputSplatURL,
            withDestinationURL: outside
        )

        XCTAssertFalse(PublishedResultResolver.hasQuickPreviousResultHint(
            projectURL: fixture.paths.root,
            metadata: fixture.metadata
        ))
    }
}

private extension PublishedResultResolverTests {
    struct Fixture {
        let cleanupRoot: URL
        let paths: ProjectPaths
        var metadata: ProjectMetadata
        let plan: ResolvedRunPlan
        var geometry: GeometryArtifact
        var training: TrainingArtifact
        var trainingManifestData: Data
        var geometryManifestDigest: String
        var outputEvidence: ValidatedPlyArtifactEvidence
        var receipt: PublishedSplatReceipt
        let publicationID: UUID

        var snapshot: ProjectArtifactSnapshot {
            ProjectArtifactSnapshot(
                metadata: metadata,
                geometryArtifact: geometry,
                trainingArtifact: training
            )
        }

        var receiptBoundSnapshot: ReceiptBoundProjectSnapshot {
            ReceiptBoundProjectSnapshot(
                snapshot: snapshot,
                trainingManifestData: trainingManifestData,
                geometryManifestDigest: geometryManifestDigest
            )
        }
    }

    func makeFixture(named name: String, writeReceipt: Bool = true) throws -> Fixture {
        let cleanupRoot = try TestFileBuilder.makeTempDir()
        let paths = ProjectPaths(root: cleanupRoot.appendingPathComponent(
            "\(name).easysplatproj",
            isDirectory: true
        ))
        try paths.ensureDirectories()
        try TestFileBuilder.writeMinimalPly(at: paths.outputSplatURL, vertexCount: 7)
        XCTAssertEqual(Darwin.chmod(paths.outputSplatURL.path, 0o600), 0)
        let outputEvidence = try ProjectArtifactValidator.validatedPlyEvidence(
            at: paths.outputSplatURL
        )

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
        let metadata = ProjectMetadata(
            id: UUID(uuidString: "9877FE00-5A9C-43A0-AB0D-FD4DABAA86B8")!,
            createdAt: Date(timeIntervalSince1970: 1_000),
            title: "Resolver fixture",
            input: .photos(folder: "Originals/Photos"),
            requestedRunOptions: requested,
            resolvedRunPlan: plan,
            viewerPreferences: ViewerPreferences(isUprightFlipActive: false),
            state: PipelineState(stage: .done, lastError: nil),
            pendingPublicationID: nil,
            stageTimings: [
                StageTimingRecord(
                    stage: .trainSplat,
                    startedAt: Date(timeIntervalSince1970: 1_500),
                    durationSeconds: 12.5
                ),
            ],
            createToViewerReadySeconds: 117.75,
            notes: "Live notes"
        )

        var geometry = makeGeometryArtifact(workerBudget: plan.geometryWorkerBudget)
        geometry.selectedFramesDigest = String(repeating: "e", count: 64)
        geometry.residualProvenance = "colmap-text-tracks-v1"

        var training = makeTrainingArtifact(outputPath: PublishedSplatReceipt.canonicalOutputPath)
        let geometryManifestDigest = String(repeating: "1", count: 64)
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
        training.outputSHA256 = outputEvidence.sha256
        training.outputBytes = Int64(outputEvidence.byteCount)
        training.gaussianCount = outputEvidence.vertexCount
        training.sceneBounds = outputEvidence.sceneBounds
        training.elapsedSeconds = 12.5
        training.datasetDerivation = makeMsplatDatasetDerivation(
            inputDigest: training.inputDigest,
            geometryDigest: training.geometryDigest,
            registeredImageNames: geometry.orderedImageNames,
            sourceGeometryManifestSHA256: geometryManifestDigest,
            sourceSelectedFramesDigest: geometry.selectedFramesDigest,
            maximumImageDimension: plan.maximumImageDimension
        )
        training.datasetDerivation.colmapProvenance = geometry.provenance.solver
        let trainingManifestData = try TrainingArtifactStore.encodedManifestData(
            training,
            projectPaths: paths
        )
        let receipt = try PublishedSplatReceiptFactory.make(
            metadata: metadata,
            resolvedRunPlan: plan,
            geometry: geometry,
            geometryManifestDigest: geometryManifestDigest,
            reboundTraining: training,
            reboundTrainingManifestData: trainingManifestData,
            outputEvidence: outputEvidence,
            projectPaths: paths,
            publicationID: publicationID,
            publishedAt: Date(timeIntervalSince1970: 2_000)
        )
        if writeReceipt {
            try self.writeReceipt(receipt, paths: paths)
        }

        return Fixture(
            cleanupRoot: cleanupRoot,
            paths: paths,
            metadata: metadata,
            plan: plan,
            geometry: geometry,
            training: training,
            trainingManifestData: trainingManifestData,
            geometryManifestDigest: geometryManifestDigest,
            outputEvidence: outputEvidence,
            receipt: receipt,
            publicationID: publicationID
        )
    }

    func makePersistedFixture(named name: String) throws -> Fixture {
        var fixture = try makeFixture(named: name, writeReceipt: false)
        do {
            let paths = fixture.paths
            let model = paths.colmapSparseURL.appendingPathComponent(
                "0",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: model,
                withIntermediateDirectories: true
            )
            let imageNames = (1...3).map {
                String(format: "frame_%06d.jpg", $0)
            }
            let pointCount = 25
            let points = (0..<pointCount).map { index in
                let rowCount = Int(ceil(Double(pointCount) / 5))
                return (
                    x: Double(index % 5 - 2) * 0.75,
                    y: (Double(index / 5) - Double(rowCount - 1) / 2) * 0.75,
                    z: 12.0
                )
            }
            var pointTracks = Array(repeating: [String](), count: points.count)
            let imageRows = imageNames.enumerated().flatMap { offset, name -> [String] in
                let imageID = offset + 1
                let centerX = (Double(offset) - Double(imageNames.count - 1) / 2) * 2
                let observations = points.enumerated().map { pointIndex, point in
                    let x = 500 * (point.x - centerX) / point.z + 320
                    let y = 500 * point.y / point.z + 240
                    pointTracks[pointIndex].append("\(imageID) \(pointIndex)")
                    return "\(x) \(y) \(pointIndex + 1)"
                }.joined(separator: " ")
                return [
                    "\(imageID) 1 0 0 0 \(-centerX) 0 0 1 \(name)",
                    observations,
                ]
            }.joined(separator: "\n") + "\n"
            let pointRows = points.enumerated().map { index, point in
                "\(index + 1) \(point.x) \(point.y) \(point.z) 255 255 255 0 "
                    + pointTracks[index].joined(separator: " ")
            }.joined(separator: "\n") + "\n"
            let modelContents = [
                "cameras.txt": "1 PINHOLE 640 480 500 500 320 240\n",
                "images.txt": imageRows,
                "points3D.txt": pointRows,
            ]
            var modelHashes: [String: String] = [:]
            for (leaf, contents) in modelContents {
                let data = Data(contents.utf8)
                try data.write(
                    to: model.appendingPathComponent(leaf),
                    options: [.atomic]
                )
                modelHashes[leaf] = SHA256.hash(data: data)
                    .map { String(format: "%02x", $0) }
                    .joined()
            }

            try Data("original input".utf8).write(
                to: paths.originalsURL.appendingPathComponent("source.jpg"),
                options: [.atomic]
            )
            for (offset, imageName) in imageNames.enumerated() {
                try Data("selected frame \(offset + 1)".utf8).write(
                    to: paths.framesSelectedURL.appendingPathComponent(imageName),
                    options: [.atomic]
                )
            }

            let analysis = try ColmapResidualAnalyzer.analyzeConditioning(
                modelDirectory: model,
                maximumRayPairEvaluations:
                    GeometryConditioningArtifact.defaultMaximumRayPairEvaluations
            )
            let modelClosure = try XCTUnwrap(
                GeometryArtifactStore.modelClosureDigest(
                    modelHashes,
                    expectedNames: ["cameras.txt", "images.txt", "points3D.txt"]
                )
            )
            var geometry = makeGeometryArtifact(
                workerBudget: fixture.plan.geometryWorkerBudget
            )
            geometry.orderedImageNames = imageNames
            geometry.orderedImageTimestamps = Array(
                repeating: nil,
                count: imageNames.count
            )
            geometry.inputDigest = try GeometryArtifactStore.inputDigest(
                projectPaths: paths
            )
            geometry.selectedFramesDigest = try GeometryArtifactStore
                .selectedFramesDigest(
                    orderedImageNames: imageNames,
                    projectPaths: paths
                )
            geometry.poseConvention = "world-to-camera"
            geometry.handedness = "right-handed"
            geometry.scaleType = "arbitrary-sim3"
            geometry.modelVersion = "none"
            geometry.residualProvenance = "colmap-text-tracks-v1"
            geometry.timings["orientation_estimation_seconds"] = 0.001
            geometry.registeredViewCount = analysis.residuals.registeredViewCount
            geometry.totalViewCount = imageNames.count
            geometry.observationCount = analysis.residuals.observationCount
            geometry.pointCount = analysis.residuals.pointCount
            geometry.medianPixelResidual = analysis.residuals.medianPixelResidual
            geometry.p90PixelResidual = analysis.residuals.p90PixelResidual
            geometry.modelHashes = modelHashes
            geometry.conditioning = GeometryConditioningArtifact(
                sourceModelClosureSHA256: modelClosure,
                measurement: analysis.measurement
            )
            geometry.cameraGroupingReceipt = ColmapCameraGroupingReceipt(
                mode: .allSelectedImagesShared,
                cameraCountBefore: imageNames.count,
                cameraCountAfter: 1,
                groupedVideoSourceCount: 0,
                groups: [
                    ColmapCameraGroupReceipt(
                        sourceGroupID: "all-selected-images",
                        memberCount: imageNames.count,
                        canonicalCameraID: 1
                    ),
                ]
            )
            geometry.pairGraph = .measured(PairGraphMeasurement(
                scheduledPairCount: 3,
                attemptedPairCount: 3,
                rawMatchedPairCount: 3,
                spatiallyVerifiedPairCount: 3,
                localPairCount: 3,
                retrievalPairCount: 0,
                loopRevisitPairCount: 0,
                connectedComponentCount: 1,
                isolatedViewCount: 0,
                descriptorlessViewCount: 0,
                componentViewCounts: [3],
                articulationViewCount: 0,
                biconnectedBlockCount: 1,
                largestBiconnectedBlockViewCount: 3,
                secondLargestBiconnectedBlockViewCount: 0,
                degreeP10: 2,
                degreeMedian: 2,
                degreeP90: 2,
                matcherAttempts: [PairMatchingAttemptArtifact(
                    attemptNumber: 1,
                    matcher: .faiss,
                    recoveryLevel: .normal,
                    outcome: .completed,
                    scheduledPairCount: 3,
                    attemptedPairCount: 3,
                    rawMatchedPairCount: 3,
                    spatiallyVerifiedPairCount: 3,
                    durationSeconds: 0.01
                )],
                pairListDigest: String(repeating: "d", count: 64),
                featureDatabaseDigest: String(repeating: "e", count: 64),
                matchingDatabaseDigest: String(repeating: "f", count: 64),
                matchingDurationSeconds: 0.01
            ))
            geometry.workerExecution.matchingInvocations[0].pairExecution?
                .scheduledPairCount = 3
            geometry.mapping.largestModelRegisteredViewCount = imageNames.count
            geometry.mapping.unionRegisteredViewCount = imageNames.count
            geometry.mapping.canonicalModelPublication = directTextPublication(
                modelHashes
            )
            _ = try GeometryWorkerExecutionArtifactStore.save(
                geometry.workerExecution,
                to: GeometryWorkerExecutionArtifactStore.canonicalURL(for: paths),
                expectedBudget: fixture.plan.geometryWorkerBudget,
                projectPaths: paths
            )

            var metadata = fixture.metadata
            metadata.input = .video(files: [])
            metadata.pendingPublicationID = nil
            try GeometryArtifactStore.persist(
                geometry,
                metadata: &metadata,
                paths: paths,
                measuredAnalysis: analysis
            )
            let geometryManifestDigest = try GeometryArtifactStore.manifestDigest(
                matching: geometry,
                at: paths.geometryManifestURL
            )

            var training = fixture.training
            training.datasetDerivation.sourceGeometryManifestSHA256 =
                geometryManifestDigest
            training.datasetDerivation.sourceSelectedFramesDigest =
                geometry.selectedFramesDigest
            training.datasetDerivation.registeredImageNames = imageNames
            training.datasetDerivation.colmapProvenance = geometry.provenance.solver
            training.datasetDerivation.maximumImageDimension =
                fixture.plan.maximumImageDimension
            training.elapsedSeconds = 12.5
            try TrainingArtifactStore.persist(training, paths: paths)
            let trainingManifestData = try TrainingArtifactStore.encodedManifestData(
                training,
                projectPaths: paths
            )
            try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

            let receipt = try PublishedSplatReceiptFactory.make(
                metadata: metadata,
                resolvedRunPlan: fixture.plan,
                geometry: geometry,
                geometryManifestDigest: geometryManifestDigest,
                reboundTraining: training,
                reboundTrainingManifestData: trainingManifestData,
                outputEvidence: fixture.outputEvidence,
                projectPaths: paths,
                publicationID: fixture.publicationID,
                publishedAt: Date(timeIntervalSince1970: 2_000)
            )
            try writeReceipt(receipt, paths: paths)

            fixture.metadata = metadata
            fixture.geometry = geometry
            fixture.training = training
            fixture.trainingManifestData = trainingManifestData
            fixture.geometryManifestDigest = geometryManifestDigest
            fixture.receipt = receipt
            return fixture
        } catch {
            try? FileManager.default.removeItem(at: fixture.cleanupRoot)
            throw error
        }
    }

    func operations(
        for fixture: Fixture
    ) -> PublishedResultResolverOperations {
        var operations = PublishedResultResolverOperations.system()
        operations.loadMetadata = { _ in fixture.metadata }
        operations.loadReceiptBoundSnapshot = { _, evidence in
            guard evidence == fixture.outputEvidence else {
                throw ResolverTestError.wrongOutputEvidence
            }
            return fixture.receiptBoundSnapshot
        }
        operations.loadLegacySnapshot = { _ in fixture.snapshot }
        return operations
    }

    func resolverSource() throws -> String {
        let testURL = URL(fileURLWithPath: #filePath)
        var ancestor = testURL.deletingLastPathComponent()
        var locatedSourceURL: URL?
        for _ in 0..<8 {
            let candidates = [
                ancestor.appendingPathComponent(
                    "Sources/EasySplatCore/Project/PublishedResultResolver.swift"
                ),
                ancestor.appendingPathComponent(
                    "EasySplatCore/Sources/EasySplatCore/Project/PublishedResultResolver.swift"
                ),
            ]
            if let match = candidates.first(where: {
                FileManager.default.fileExists(atPath: $0.path)
            }) {
                locatedSourceURL = match
                break
            }
            ancestor.deleteLastPathComponent()
        }
        let sourceURL = try XCTUnwrap(locatedSourceURL)
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    func writeReceipt(_ receipt: PublishedSplatReceipt, paths: ProjectPaths) throws {
        try writeReceiptData(
            PublishedSplatReceiptStore.encode(receipt),
            paths: paths
        )
    }

    func writeReceiptData(_ data: Data, paths: ProjectPaths) throws {
        try data.write(to: paths.outputSplatReceiptURL, options: [.atomic])
        XCTAssertEqual(Darwin.chmod(paths.outputSplatReceiptURL.path, 0o600), 0)
    }

    func writeBackfillResidue(
        _ receipt: PublishedSplatReceipt,
        paths: ProjectPaths,
        suffix: String = ".json"
    ) throws -> URL {
        let url = paths.outputURL.appendingPathComponent(
            ".published-result-backfill-"
                + receipt.publicationID.uuidString.lowercased()
                + suffix
        )
        try PublishedSplatReceiptStore.encode(receipt).write(to: url)
        XCTAssertEqual(Darwin.chmod(url.path, 0o600), 0)
        return url
    }

    func replacing(
        _ receipt: PublishedSplatReceipt,
        projectID: UUID? = nil,
        lineage: PublishedSplatLineage? = nil,
        reconstruction: PublishedReconstructionSummary? = nil
    ) -> PublishedSplatReceipt {
        let original = receipt.presentation
        return PublishedSplatReceipt(
            schemaVersion: receipt.schemaVersion,
            publicationID: receipt.publicationID,
            projectID: projectID ?? receipt.projectID,
            publishedAt: receipt.publishedAt,
            outputPath: receipt.outputPath,
            outputEvidence: receipt.outputEvidence,
            lineage: lineage ?? receipt.lineage,
            presentation: PublishedResultPresentation(
                requestedRunOptions: original.requestedRunOptions,
                resolvedRunPlan: original.resolvedRunPlan,
                reconstruction: reconstruction ?? original.reconstruction,
                orientation: original.orientation,
                stageTimings: original.stageTimings,
                autoTunerSnapshot: original.autoTunerSnapshot,
                trainerVersion: original.trainerVersion,
                runtimeVersion: original.runtimeVersion,
                completedIteration: original.completedIteration,
                trainingDurationSeconds: original.trainingDurationSeconds,
                createToViewerReadySeconds: original.createToViewerReadySeconds
            )
        )
    }
}

private enum ResolverTestError: Error {
    case invalidSnapshot
    case unexpectedCurrentArtifactRead
    case unexpectedLegacyArtifactRead
    case wrongOutputEvidence
}

private final class ResolverCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class ResolverMetadataSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProjectMetadata]

    init(_ values: [ProjectMetadata]) {
        self.values = values
    }

    func next() throws -> ProjectMetadata {
        try lock.withLock {
            guard let value = values.first else {
                throw ResolverTestError.invalidSnapshot
            }
            if values.count > 1 {
                values.removeFirst()
            }
            return value
        }
    }
}

private final class ResolverMetadataReadPlan: @unchecked Sendable {
    enum Step {
        case value(ProjectMetadata)
        case missing
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var reads = 0

    init(_ steps: [Step]) {
        self.steps = steps
    }

    var readCount: Int { lock.withLock { reads } }

    func next() throws -> ProjectMetadata {
        try lock.withLock {
            guard let step = steps.first else {
                throw ResolverTestError.invalidSnapshot
            }
            steps.removeFirst()
            reads += 1
            switch step {
            case .value(let metadata):
                return metadata
            case .missing:
                throw CocoaError(.fileReadNoSuchFile)
            }
        }
    }
}
