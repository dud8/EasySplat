import Darwin
import Foundation
import XCTest
@testable import EasySplatCore

final class PublishedResultPairStoreTests: XCTestCase {
    func testReconcileIfPresentAllowsMissingOutputAndRejectsUnsafeOutputLeaf() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)

        XCTAssertNoThrow(
            try PublishedResultPairStore.reconcileIfPresent(projectPaths: paths)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.outputURL.path))

        XCTAssertTrue(FileManager.default.createFile(
            atPath: paths.outputURL.path,
            contents: Data("not a directory".utf8)
        ))
        XCTAssertThrowsError(
            try PublishedResultPairStore.reconcileIfPresent(projectPaths: paths)
        ) { error in
            XCTAssertEqual(error as? PublishedResultPairError, .unsafeOutput)
        }
    }

    func testMissingIncompleteAndTamperedPairsNeverGrantAuthority() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .unavailable(.missingPair)
        )

        let source = fixture.root.appendingPathComponent("source.ply")
        _ = try writeSplat(at: source, x: 1)
        try FileManager.default.copyItem(at: source, to: fixture.paths.outputSplatURL)
        XCTAssertEqual(Darwin.chmod(fixture.paths.outputSplatURL.path, 0o600), 0)
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .unavailable(.incompletePair)
        )

        try FileManager.default.removeItem(at: fixture.paths.outputSplatURL)
        let published = try publish(source: source, paths: fixture.paths)
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(published)
        )

        try mutateFirstFloatSameSize(at: fixture.paths.outputSplatURL)
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .unavailable(.evidenceMismatch)
        )
    }

    func testFirstPublicationCommitsReceiptLastAndResolvesWithOnePlyValidation() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("source.ply")
        let evidence = try writeSplat(at: source, x: 2)
        let receipt = makeReceipt(evidence: evidence)

        let publication = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: receipt,
            projectPaths: fixture.paths
        )
        XCTAssertEqual(publication.receipt, receipt)
        XCTAssertEqual(publication.outputEvidence, evidence)
        XCTAssertEqual(DarwinMode(at: fixture.paths.outputSplatURL), 0o600)
        XCTAssertEqual(DarwinMode(at: fixture.paths.outputSplatReceiptURL), 0o600)

        let counter = LockedCounter()
        var operations = PublishedResultPairOperations.system()
        operations.willValidatePly = { _ in
            counter.increment()
        }
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(
                projectPaths: fixture.paths,
                operations: operations
            ),
            .available(publication)
        )
        XCTAssertEqual(counter.value, 1)
    }

    func testPublicationBuildsReceiptFromTheDescriptorValidatedSourceEvidence() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("source.ply")
        let expectedEvidence = try writeSplat(at: source, x: 2)
        var suppliedEvidence: ValidatedPlyArtifactEvidence?

        let publication = try PublishedResultPairStore.publish(
            sourceURL: source,
            projectPaths: fixture.paths
        ) { evidence in
            suppliedEvidence = evidence
            return makeReceipt(evidence: evidence)
        }

        XCTAssertEqual(suppliedEvidence, expectedEvidence)
        XCTAssertEqual(publication.outputEvidence, expectedEvidence)
        XCTAssertEqual(publication.receipt.outputEvidence, expectedEvidence)
    }

    func testPostCommitFailureLeavesTheValidatedPairAndRunsCallbackOnce() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("source.ply")
        let evidence = try writeSplat(at: source, x: 2)
        let receipt = makeReceipt(evidence: evidence)
        var callbackCount = 0

        XCTAssertThrowsError(
            try PublishedResultPairStore.publish(
                sourceURL: source,
                receipt: receipt,
                projectPaths: fixture.paths,
                afterCommit: { committed in
                    callbackCount += 1
                    XCTAssertEqual(committed.receipt, receipt)
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
                }
            )
        )

        XCTAssertEqual(callbackCount, 1)
        guard case .available(let committed) = try PublishedResultPairStore.resolve(
            projectPaths: fixture.paths
        ) else {
            return XCTFail("The receipt commit must survive a later manifest failure.")
        }
        XCTAssertEqual(committed.receipt, receipt)
        XCTAssertTrue(activeTransactionURLs(in: fixture.paths).isEmpty)
    }

    func testValidatedExistingPairCanCommitDependentStateUnderItsLock() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("source.ply")
        let evidence = try writeSplat(at: source, x: 2)
        let receipt = makeReceipt(evidence: evidence)
        let published = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: receipt,
            projectPaths: fixture.paths
        )
        var committed: ValidatedPublishedResult?

        let adopted = try PublishedResultPairStore.commitResolvedResultIf(
            projectPaths: fixture.paths,
            matches: { $0.receipt.publicationID == receipt.publicationID },
            afterCommit: { committed = $0 }
        )

        XCTAssertEqual(adopted, published)
        XCTAssertEqual(committed, published)
    }

    func testPublicationAcceptsCanonicalRoundTripOfSubsecondRuntimeDates() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("source.ply")
        let evidence = try writeSplat(at: source, x: 2)
        let receipt = makeReceipt(
            evidence: evidence,
            publishedAt: Date(timeIntervalSince1970: 1_767_225_600.987_654)
        )

        let publication = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: receipt,
            projectPaths: fixture.paths
        )

        XCTAssertEqual(publication.receipt.publicationID, receipt.publicationID)
        XCTAssertEqual(publication.outputEvidence, evidence)
    }

    func testReplacingPairPreservesOldAuthorityUntilNewReceiptCommit() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldSource = fixture.root.appendingPathComponent("old.ply")
        let newSource = fixture.root.appendingPathComponent("new.ply")
        let oldEvidence = try writeSplat(at: oldSource, x: 3)
        let newEvidence = try writeSplat(at: newSource, x: 4)
        let old = try PublishedResultPairStore.publish(
            sourceURL: oldSource,
            receipt: makeReceipt(
                evidence: oldEvidence,
                publicationID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
            ),
            projectPaths: fixture.paths
        )

        let checkpoints = LockedValues<PublishedResultPairCheckpoint>()
        var operations = PublishedResultPairOperations.system()
        operations.didReachCheckpoint = { checkpoint in checkpoints.append(checkpoint) }
        let new = try PublishedResultPairStore.publish(
            sourceURL: newSource,
            receipt: makeReceipt(
                evidence: newEvidence,
                publicationID: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
            ),
            projectPaths: fixture.paths,
            operations: operations
        )

        XCTAssertNotEqual(old.receipt.publicationID, new.receipt.publicationID)
        XCTAssertTrue(checkpoints.values.contains(.previousPairMoved))
        XCTAssertLessThan(
            try XCTUnwrap(checkpoints.values.firstIndex(of: .newPlyInstalled)),
            try XCTUnwrap(checkpoints.values.firstIndex(of: .newReceiptInstalled))
        )
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(new)
        )
    }

    func testPublicationIdentityCannotBeReusedForDifferentEvidence() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstSource = fixture.root.appendingPathComponent("first.ply")
        let secondSource = fixture.root.appendingPathComponent("second.ply")
        let firstEvidence = try writeSplat(at: firstSource, x: 2)
        let secondEvidence = try writeSplat(at: secondSource, x: 9)
        let publicationID = UUID(uuidString: "12121212-3434-4567-8567-898989898989")!
        let first = try PublishedResultPairStore.publish(
            sourceURL: firstSource,
            receipt: makeReceipt(
                evidence: firstEvidence,
                publicationID: publicationID
            ),
            projectPaths: fixture.paths
        )

        XCTAssertThrowsError(
            try PublishedResultPairStore.publish(
                sourceURL: secondSource,
                receipt: makeReceipt(
                    evidence: secondEvidence,
                    publicationID: publicationID
                ),
                projectPaths: fixture.paths
            )
        ) { error in
            guard case .publicationConflict = error as? PublishedResultPairError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(first)
        )
    }

    func testCancellationBeforeReceiptCommitRestoresOldPairAndAfterCommitKeepsNewPair() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldSource = fixture.root.appendingPathComponent("old.ply")
        let newSource = fixture.root.appendingPathComponent("new.ply")
        let oldEvidence = try writeSplat(at: oldSource, x: 5)
        let newEvidence = try writeSplat(at: newSource, x: 6)
        let old = try PublishedResultPairStore.publish(
            sourceURL: oldSource,
            receipt: makeReceipt(evidence: oldEvidence),
            projectPaths: fixture.paths
        )

        let cancellationBeforeMove = LockedFlag()
        let beforeMoveCheckpoints = LockedValues<PublishedResultPairCheckpoint>()
        var beforeMoveOperations = PublishedResultPairOperations.system()
        beforeMoveOperations.didReachCheckpoint = { checkpoint in
            beforeMoveCheckpoints.append(checkpoint)
            if checkpoint == .prepared { cancellationBeforeMove.set() }
        }
        XCTAssertThrowsError(
            try PublishedResultPairStore.publish(
                sourceURL: newSource,
                receipt: makeReceipt(
                    evidence: newEvidence,
                    publicationID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
                ),
                projectPaths: fixture.paths,
                operations: beforeMoveOperations,
                shouldCancel: { cancellationBeforeMove.value }
            )
        ) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(beforeMoveCheckpoints.values.contains(.prepared))
        XCTAssertFalse(beforeMoveCheckpoints.values.contains(.previousPlyMoved))
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(old)
        )

        let cancellationDuringRollback = LockedFlag()
        var rollbackOperations = PublishedResultPairOperations.system()
        rollbackOperations.didReachCheckpoint = { checkpoint in
            if checkpoint == .previousPlyMoved { cancellationDuringRollback.set() }
        }
        XCTAssertThrowsError(
            try PublishedResultPairStore.publish(
                sourceURL: newSource,
                receipt: makeReceipt(
                    evidence: newEvidence,
                    publicationID: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
                ),
                projectPaths: fixture.paths,
                operations: rollbackOperations,
                shouldCancel: { cancellationDuringRollback.value }
            )
        ) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(old)
        )

        let committedReceipt = makeReceipt(
            evidence: newEvidence,
            publicationID: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        )
        let cancellationAfterCommit = LockedFlag()
        let callbackCount = LockedCounter()
        var commitOperations = PublishedResultPairOperations.system()
        commitOperations.didReachCheckpoint = { checkpoint in
            if checkpoint == .newReceiptInstalled { cancellationAfterCommit.set() }
        }
        XCTAssertThrowsError(
            try PublishedResultPairStore.publish(
                sourceURL: newSource,
                receipt: committedReceipt,
                projectPaths: fixture.paths,
                operations: commitOperations,
                shouldCancel: { cancellationAfterCommit.value },
                afterCommit: { _ in callbackCount.increment() }
            )
        ) { XCTAssertTrue($0 is CancellationError) }
        guard case .available(let committed) = try PublishedResultPairStore.resolve(
            projectPaths: fixture.paths
        ) else {
            return XCTFail("Expected the receipt-committed publication to remain available")
        }
        XCTAssertEqual(committed.receipt, committedReceipt)
        XCTAssertEqual(committed.outputEvidence, newEvidence)
        XCTAssertEqual(callbackCount.value, 1)
        XCTAssertEqual(try transactionPayloadBytes(in: fixture.paths), 0)
    }

    func testCanonicalMutationAfterValidationNeverReturnsStaleAuthority() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldSource = fixture.root.appendingPathComponent("old.ply")
        let newSource = fixture.root.appendingPathComponent("new.ply")
        let oldEvidence = try writeSplat(at: oldSource, x: 5)
        let newEvidence = try writeSplat(at: newSource, x: 6)
        let old = try PublishedResultPairStore.publish(
            sourceURL: oldSource,
            receipt: makeReceipt(evidence: oldEvidence),
            projectPaths: fixture.paths
        )
        let mutation = LockedResult<Void>()
        var operations = PublishedResultPairOperations.system()
        operations.didReachCheckpoint = { checkpoint in
            guard checkpoint == .canonicalPairValidated else { return }
            mutation.capture {
                try mutatePublishedPairTestPly(at: fixture.paths.outputSplatURL)
            }
        }

        XCTAssertThrowsError(
            try PublishedResultPairStore.publish(
                sourceURL: newSource,
                receipt: makeReceipt(evidence: newEvidence, publicationID: UUID()),
                projectPaths: fixture.paths,
                operations: operations
            )
        )
        XCTAssertNoThrow(try mutation.get())
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(old)
        )
        XCTAssertEqual(try transactionPayloadBytes(in: fixture.paths), 0)
    }

    func testJournalPhaseMatrixRestoresOldBeforeReceiptCommitAndKeepsNewAfter() throws {
        for phase in PublishedResultPairJournalPhase.allCases {
            let fixture = try makeCrashFixture(phase: phase, hasPrevious: true)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            if phase == .newPlyInstalled,
               let transaction = activeTransactionURLs(in: fixture.paths).first {
                let prepared = try String(
                    contentsOf: transaction.appendingPathComponent(
                        PublishedResultPairJournalPhase.prepared.leaf
                    ),
                    encoding: .utf8
                )
                XCTAssertTrue(prepared.contains("new.ply"), prepared)
            }

            let expected = phase.rawValue < PublishedResultPairJournalPhase.receiptCommitted.rawValue
                ? fixture.previous
                : fixture.next
            do {
                try PublishedResultPairStore.reconcile(projectPaths: fixture.paths)
            } catch {
                XCTFail("Phase \(phase) reconciliation failed: \(error)")
            }
            XCTAssertEqual(
                try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
                .available(try XCTUnwrap(expected)),
                "Phase: \(phase)"
            )
            XCTAssertEqual(
                try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
                .available(try XCTUnwrap(expected)),
                "Idempotent phase: \(phase)"
            )
            XCTAssertTrue(activeTransactionURLs(in: fixture.paths).isEmpty)
            XCTAssertEqual(
                try transactionPayloadBytes(in: fixture.paths),
                0,
                "Phase: \(phase)"
            )
        }
    }

    func testReconciliationResolutionHashesExactlyOnePlyPerDecision() throws {
        for phase in PublishedResultPairJournalPhase.allCases {
            let fixture = try makeCrashFixture(phase: phase, hasPrevious: true)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let counter = LockedCounter()
            var operations = PublishedResultPairOperations.system()
            operations.willValidatePly = { _ in counter.increment() }

            guard case .available = try PublishedResultPairStore.resolve(
                projectPaths: fixture.paths,
                operations: operations
            ) else {
                return XCTFail("Phase \(phase) did not resolve a pair")
            }
            XCTAssertEqual(counter.value, 1, "Phase: \(phase)")
        }
    }

    func testPreparedCrashAfterPreviousPlyRenameBeforePhaseRecordRestoresExactPreviousPair() throws {
        let fixture = try makeCrashFixture(phase: .prepared, hasPrevious: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transaction = try XCTUnwrap(activeTransactionURLs(in: fixture.paths).first)
        try FileManager.default.moveItem(
            at: fixture.paths.outputSplatURL,
            to: transaction.appendingPathComponent("old.ply")
        )

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(try XCTUnwrap(fixture.previous))
        )
        XCTAssertTrue(activeTransactionURLs(in: fixture.paths).isEmpty)
        XCTAssertEqual(try transactionPayloadBytes(in: fixture.paths), 0)
    }

    func testPreviousPlyMovedCrashAfterPreviousReceiptRenameBeforePhaseRecordRestoresExactPreviousPair() throws {
        let fixture = try makeCrashFixture(
            phase: .previousPlyMoved,
            hasPrevious: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transaction = try XCTUnwrap(activeTransactionURLs(in: fixture.paths).first)
        try FileManager.default.moveItem(
            at: fixture.paths.outputSplatReceiptURL,
            to: transaction.appendingPathComponent("old-receipt.json")
        )

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(try XCTUnwrap(fixture.previous))
        )
        XCTAssertTrue(activeTransactionURLs(in: fixture.paths).isEmpty)
        XCTAssertEqual(try transactionPayloadBytes(in: fixture.paths), 0)
    }

    func testPreparedRecoveryRejectsByteIdenticalReplacementOfUntouchedPreviousPair() throws {
        let fixture = try makeCrashFixture(phase: .prepared, hasPrevious: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let displacedPly = fixture.root.appendingPathComponent("displaced-previous.ply")
        let displacedReceipt = fixture.root.appendingPathComponent(
            "displaced-previous-receipt.json"
        )
        try FileManager.default.moveItem(
            at: fixture.paths.outputSplatURL,
            to: displacedPly
        )
        try FileManager.default.moveItem(
            at: fixture.paths.outputSplatReceiptURL,
            to: displacedReceipt
        )
        try FileManager.default.copyItem(
            at: displacedPly,
            to: fixture.paths.outputSplatURL
        )
        try FileManager.default.copyItem(
            at: displacedReceipt,
            to: fixture.paths.outputSplatReceiptURL
        )
        XCTAssertEqual(Darwin.chmod(fixture.paths.outputSplatURL.path, 0o600), 0)
        XCTAssertEqual(
            Darwin.chmod(fixture.paths.outputSplatReceiptURL.path, 0o600),
            0
        )

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .conflict(.pendingTransaction)
        )
        XCTAssertEqual(activeTransactionURLs(in: fixture.paths).count, 1)
    }

    func testOpenFailureAfterBuildCreationDoesNotBlockPreviousPair() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldSource = fixture.root.appendingPathComponent("old-source.ply")
        let newSource = fixture.root.appendingPathComponent("new-source.ply")
        let oldEvidence = try writeSplat(at: oldSource, x: 7)
        let newEvidence = try writeSplat(at: newSource, x: 8)
        let previous = try PublishedResultPairStore.publish(
            sourceURL: oldSource,
            receipt: makeReceipt(evidence: oldEvidence),
            projectPaths: fixture.paths
        )
        let system = PublishedResultPairOperations.system()
        let failure = OneShotCallFailure(targetCall: 1)
        var operations = system
        operations.openTransactionDirectory = { parent, name in
            if failure.shouldFail() {
                Darwin.__error().pointee = EMFILE
                return -1
            }
            return system.openTransactionDirectory(parent, name)
        }

        XCTAssertThrowsError(try PublishedResultPairStore.publish(
            sourceURL: newSource,
            receipt: makeReceipt(evidence: newEvidence, publicationID: UUID()),
            projectPaths: fixture.paths,
            operations: operations
        ))

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(previous)
        )
        XCTAssertFalse(try outputNames(in: fixture.paths).contains {
            $0.hasPrefix(".published-result-build-")
                || $0.hasPrefix(".published-result-build-authority-")
        })
    }

    func testPreJournalPartialPlaceholderRecoversOnlyWithBuildAuthority() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldSource = fixture.root.appendingPathComponent("old-source.ply")
        let newSource = fixture.root.appendingPathComponent("new-source.ply")
        let oldEvidence = try writeSplat(at: oldSource, x: 7)
        let newEvidence = try writeSplat(at: newSource, x: 8)
        let previous = try PublishedResultPairStore.publish(
            sourceURL: oldSource,
            receipt: makeReceipt(evidence: oldEvidence),
            projectPaths: fixture.paths
        )
        let system = PublishedResultPairOperations.system()
        let interruption = OneShotCallFailure(targetCall: 1)
        var operations = system
        operations.didReachCheckpoint = { checkpoint in
            guard checkpoint == .transactionBuildOwnershipDurable else { return }
            interruption.markReached()
        }
        operations.renameExclusive = {
            sourceDirectory, sourceName, destinationDirectory, destinationName in
            if interruption.consumeReached(),
               destinationName == PublishedResultPairJournalPhase.created.leaf {
                Darwin.__error().pointee = EIO
                return -1
            }
            return system.renameExclusive(
                sourceDirectory,
                sourceName,
                destinationDirectory,
                destinationName
            )
        }
        operations.willQuarantineOwnedEntry = { _ in
            throw NSError(
                domain: "PublishedResultPairStoreTests.preactivation-crash",
                code: 1
            )
        }

        XCTAssertThrowsError(try PublishedResultPairStore.publish(
            sourceURL: newSource,
            receipt: makeReceipt(evidence: newEvidence, publicationID: UUID()),
            projectPaths: fixture.paths,
            operations: operations
        ))
        XCTAssertTrue(try outputNames(in: fixture.paths).contains {
            $0.hasPrefix(".published-result-build-")
        })

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(previous)
        )
        XCTAssertFalse(try outputNames(in: fixture.paths).contains {
            $0.hasPrefix(".published-result-build-")
                || $0.hasPrefix(".published-result-build-authority-")
        })
    }

    func testPreparedRecoveryRejectsSameInodeReceiptMutationWithRestoredMtime() throws {
        for previousPlyWasMoved in [false, true] {
            let fixture = try makeCrashFixture(phase: .prepared, hasPrevious: true)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            if previousPlyWasMoved {
                let transaction = try XCTUnwrap(
                    activeTransactionURLs(in: fixture.paths).first
                )
                try FileManager.default.moveItem(
                    at: fixture.paths.outputSplatURL,
                    to: transaction.appendingPathComponent("old.ply")
                )
            }
            try replaceEqualLengthBytesRestoringTimes(
                at: fixture.paths.outputSplatReceiptURL,
                replacing: Data("msplat-test".utf8),
                with: Data("forged-test".utf8)
            )

            XCTAssertEqual(
                try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
                .conflict(.pendingTransaction),
                "Previous PLY moved: \(previousPlyWasMoved)"
            )
            XCTAssertEqual(
                activeTransactionURLs(in: fixture.paths).count,
                1,
                "Previous PLY moved: \(previousPlyWasMoved)"
            )
        }
    }

    func testReceiptCommittedRestoredMtimePlyMutationHashesOnlyRestoredPair() throws {
        let fixture = try makeCrashFixture(phase: .receiptCommitted, hasPrevious: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try mutatePublishedPairTestPlyRestoringTimes(
            at: fixture.paths.outputSplatURL
        )
        let counter = LockedCounter()
        var operations = PublishedResultPairOperations.system()
        operations.willValidatePly = { _ in counter.increment() }

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(
                projectPaths: fixture.paths,
                operations: operations
            ),
            .available(try XCTUnwrap(fixture.previous))
        )
        XCTAssertEqual(counter.value, 1)
    }

    func testPrePhaseOldFileWithDifferentInodeRemainsConflict() throws {
        let fixture = try makeCrashFixture(phase: .prepared, hasPrevious: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transaction = try XCTUnwrap(activeTransactionURLs(in: fixture.paths).first)
        let foreign = transaction.appendingPathComponent("old.ply")
        try Data("foreign-old-ply".utf8).write(to: foreign)
        XCTAssertEqual(Darwin.chmod(foreign.path, 0o600), 0)

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .conflict(.pendingTransaction)
        )
        XCTAssertEqual(try Data(contentsOf: foreign), Data("foreign-old-ply".utf8))
    }

    func testMarkerlessInactiveBuildIsPreservedWithoutTouchingCanonicalPair() throws {
        let fixture = try makeCrashFixture(phase: .created, hasPrevious: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let canonicalPly = try Data(contentsOf: fixture.paths.outputSplatURL)
        let canonicalReceipt = try Data(
            contentsOf: fixture.paths.outputSplatReceiptURL
        )
        let active = try XCTUnwrap(activeTransactionURLs(in: fixture.paths).first)
        let build = fixture.paths.outputURL.appendingPathComponent(
            active.lastPathComponent.replacingOccurrences(
                of: ".published-result-tx-",
                with: ".published-result-build-"
            ),
            isDirectory: true
        )
        try FileManager.default.moveItem(at: active, to: build)

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .conflict(.pendingTransaction)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: build.path))
        XCTAssertEqual(try Data(contentsOf: fixture.paths.outputSplatURL), canonicalPly)
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.outputSplatReceiptURL),
            canonicalReceipt
        )
    }

    func testMalformedInactiveBuildIsPreservedAsConflict() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let build = fixture.paths.outputURL.appendingPathComponent(
            ".published-result-build-11111111-aaaa-4aaa-8aaa-111111111111",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: build,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(Darwin.chmod(build.path, 0o700), 0)

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .conflict(.pendingTransaction)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: build.path))
    }

    func testPartialViewerTimingBuildRecoversAfterInterruptedDiscard() throws {
        let timing = try makeTimingFixture()
        defer { try? FileManager.default.removeItem(at: timing.root) }
        let system = PublishedResultPairOperations.system()
        let cleanup = OneShotCallFailure(targetCall: 2)
        var operations = system
        operations.renameExclusive = {
            sourceDirectory, sourceName, destinationDirectory, destinationName in
            if sourceName.hasPrefix(".published-receipt-build-"),
               destinationName.hasPrefix(".published-receipt-tx-") {
                Darwin.__error().pointee = EIO
                return -1
            }
            return system.renameExclusive(
                sourceDirectory,
                sourceName,
                destinationDirectory,
                destinationName
            )
        }
        operations.willQuarantineOwnedEntry = { _ in
            if cleanup.shouldFail() {
                throw NSError(
                    domain: "PublishedResultPairStoreTests.partial-timing-discard",
                    code: 1
                )
            }
        }
        XCTAssertThrowsError(try PublishedResultPairStore.recordFirstViewerReadyTiming(
            142.25,
            expectedPublicationID: timing.receipt.publicationID,
            projectPaths: timing.paths,
            operations: operations
        ))
        XCTAssertTrue(try outputNames(in: timing.paths).contains {
            $0.hasPrefix(".published-receipt-build-")
        })

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: timing.paths),
            .available(timing.published)
        )
        XCTAssertFalse(try outputNames(in: timing.paths).contains {
            $0.hasPrefix(".published-receipt-build-")
        })
    }

    func testPendingViewerTimingBuildRecoversWhenCanonicalPlyMetadataChanged() throws {
        let timing = try makeTimingFixture()
        defer { try? FileManager.default.removeItem(at: timing.root) }
        let system = PublishedResultPairOperations.system()
        var operations = system
        operations.renameExclusive = {
            sourceDirectory, sourceName, destinationDirectory, destinationName in
            if sourceName.hasPrefix(".published-receipt-build-"),
               destinationName.hasPrefix(".published-receipt-tx-") {
                Darwin.__error().pointee = EIO
                return -1
            }
            return system.renameExclusive(
                sourceDirectory,
                sourceName,
                destinationDirectory,
                destinationName
            )
        }
        operations.willQuarantineOwnedEntry = { _ in
            throw NSError(
                domain: "PublishedResultPairStoreTests.pending-timing-build",
                code: 1
            )
        }
        XCTAssertThrowsError(try PublishedResultPairStore.recordFirstViewerReadyTiming(
            142.25,
            expectedPublicationID: timing.receipt.publicationID,
            projectPaths: timing.paths,
            operations: operations
        ))
        var before = stat()
        XCTAssertEqual(Darwin.lstat(timing.paths.outputSplatURL.path, &before), 0)
        XCTAssertEqual(Darwin.chmod(timing.paths.outputSplatURL.path, 0o600), 0)
        var after = stat()
        XCTAssertEqual(Darwin.lstat(timing.paths.outputSplatURL.path, &after), 0)
        XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertEqual(before.st_size, after.st_size)
        XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
        XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
        XCTAssertTrue(
            before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec
                || before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec
        )
        let validations = LockedCounter()
        var resolveOperations = PublishedResultPairOperations.system()
        resolveOperations.willValidatePly = { _ in validations.increment() }

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(
                projectPaths: timing.paths,
                operations: resolveOperations
            ),
            .available(timing.published)
        )
        XCTAssertEqual(validations.value, 1)
        XCTAssertFalse(try outputNames(in: timing.paths).contains {
            $0.hasPrefix(".published-receipt-build-")
        })
    }

    func testForgedRetiredViewerTimingAuthorityPreservesForeignReservedFiles() throws {
        let fixture = try makeRetiredTimingFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let createdJournal = fixture.retired.appendingPathComponent(
            "journal-created.json"
        )
        let savedJournal = fixture.root.appendingPathComponent("genuine-created.json")
        try FileManager.default.moveItem(at: createdJournal, to: savedJournal)
        let foreignBytes = Data("foreign-reserved-journal".utf8)
        try foreignBytes.write(to: createdJournal, options: .withoutOverwriting)
        XCTAssertEqual(Darwin.chmod(createdJournal.path, 0o600), 0)
        var authority = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.authority))
                as? [String: Any]
        )
        var owned = try XCTUnwrap(authority["ownedFiles"] as? [String: Any])
        owned["journal-created.json"] = try journalFileIdentityObject(at: createdJournal)
        authority["ownedFiles"] = owned
        try JSONSerialization.data(withJSONObject: authority, options: [.sortedKeys])
            .write(to: fixture.authority)
        XCTAssertEqual(Darwin.chmod(fixture.authority.path, 0o600), 0)

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .conflict(.pendingTransaction)
        )
        XCTAssertEqual(try Data(contentsOf: createdJournal), foreignBytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.authority.path))
    }

    func testStandaloneWellFormedForeignTimingAuthorityIsPreservedAsConflict() throws {
        let fixture = try makeRetiredTimingFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let authorityBytes = try Data(contentsOf: fixture.authority)
        try FileManager.default.removeItem(at: fixture.retired)
        let genuine = fixture.root.appendingPathComponent("genuine-parent-authority.json")
        try FileManager.default.moveItem(at: fixture.authority, to: genuine)
        try authorityBytes.write(to: fixture.authority, options: .withoutOverwriting)
        XCTAssertEqual(Darwin.chmod(fixture.authority.path, 0o600), 0)

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .conflict(.pendingTransaction)
        )
        XCTAssertEqual(try Data(contentsOf: fixture.authority), authorityBytes)
    }

    func testCommitReceiptBoundStateRunsOnlyForExactGenerationWithoutPlyValidation() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("receipt-bound-source.ply")
        let evidence = try writeSplat(at: source, x: 6)
        let receipt = makeReceipt(evidence: evidence)
        let published = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: receipt,
            projectPaths: fixture.paths
        )
        let generation = try XCTUnwrap(published.generation)
        let closureCalls = LockedCounter()
        let plyValidations = LockedCounter()
        var operations = PublishedResultPairOperations.system()
        operations.willValidatePly = { _ in plyValidations.increment() }

        XCTAssertFalse(try PublishedResultPairStore.commitReceiptBoundStateIf(
            projectPaths: fixture.paths,
            expectedGeneration: generation,
            expectedViewerReadySeconds: 117.76,
            operations: operations,
            afterValidation: { closureCalls.increment() }
        ))
        XCTAssertTrue(try PublishedResultPairStore.commitReceiptBoundStateIf(
            projectPaths: fixture.paths,
            expectedGeneration: generation,
            expectedViewerReadySeconds: 117.75,
            operations: operations,
            afterValidation: { closureCalls.increment() }
        ))
        try FileManager.default.moveItem(
            at: fixture.paths.outputSplatReceiptURL,
            to: fixture.root.appendingPathComponent("missing-authority-receipt.json")
        )
        XCTAssertFalse(try PublishedResultPairStore.commitReceiptBoundStateIf(
            projectPaths: fixture.paths,
            expectedGeneration: generation,
            expectedViewerReadySeconds: 117.75,
            operations: operations,
            afterValidation: { closureCalls.increment() }
        ))
        XCTAssertEqual(closureCalls.value, 1)
        XCTAssertEqual(plyValidations.value, 0)
    }

    func testCommitReceiptBoundStateReturnsFalseAfterPublicationSwap() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstSource = fixture.root.appendingPathComponent("first-bound-source.ply")
        let secondSource = fixture.root.appendingPathComponent("second-bound-source.ply")
        let firstEvidence = try writeSplat(at: firstSource, x: 6)
        let secondEvidence = try writeSplat(at: secondSource, x: 7)
        let firstReceipt = makeReceipt(evidence: firstEvidence)
        let firstPublished = try PublishedResultPairStore.publish(
            sourceURL: firstSource,
            receipt: firstReceipt,
            projectPaths: fixture.paths
        )
        let firstGeneration = try XCTUnwrap(firstPublished.generation)
        _ = try PublishedResultPairStore.publish(
            sourceURL: secondSource,
            receipt: makeReceipt(
                evidence: secondEvidence,
                publicationID: UUID()
            ),
            projectPaths: fixture.paths
        )
        let closureCalls = LockedCounter()

        XCTAssertFalse(try PublishedResultPairStore.commitReceiptBoundStateIf(
            projectPaths: fixture.paths,
            expectedGeneration: firstGeneration,
            expectedViewerReadySeconds: 117.75,
            afterValidation: { closureCalls.increment() }
        ))
        XCTAssertEqual(closureCalls.value, 0)
    }

    func testCommitReceiptBoundStateRejectsReceiptReplacementDuringClosure() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("replaced-bound-source.ply")
        let evidence = try writeSplat(at: source, x: 6)
        let receipt = makeReceipt(evidence: evidence)
        let published = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: receipt,
            projectPaths: fixture.paths
        )
        let generation = try XCTUnwrap(published.generation)
        let displaced = fixture.root.appendingPathComponent("displaced-receipt.json")

        XCTAssertThrowsError(try PublishedResultPairStore.commitReceiptBoundStateIf(
            projectPaths: fixture.paths,
            expectedGeneration: generation,
            expectedViewerReadySeconds: 117.75,
            afterValidation: {
                try FileManager.default.moveItem(
                    at: fixture.paths.outputSplatReceiptURL,
                    to: displaced
                )
                try FileManager.default.copyItem(
                    at: displaced,
                    to: fixture.paths.outputSplatReceiptURL
                )
                XCTAssertEqual(
                    Darwin.chmod(fixture.paths.outputSplatReceiptURL.path, 0o600),
                    0
                )
            }
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: displaced.path))
    }

    func testCommitReceiptBoundStateRejectsSamePublicationReceiptSubstitution() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("substituted-receipt-source.ply")
        let evidence = try writeSplat(at: source, x: 6)
        let receipt = makeReceipt(evidence: evidence)
        let published = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: receipt,
            projectPaths: fixture.paths
        )
        let generation = try XCTUnwrap(published.generation)
        let replacement = makeReceipt(
            evidence: evidence,
            publicationID: receipt.publicationID,
            publishedAt: receipt.publishedAt.addingTimeInterval(1)
        )
        try FileManager.default.removeItem(at: fixture.paths.outputSplatReceiptURL)
        try PublishedSplatReceiptStore.encode(replacement).write(
            to: fixture.paths.outputSplatReceiptURL,
            options: .withoutOverwriting
        )
        XCTAssertEqual(
            Darwin.chmod(fixture.paths.outputSplatReceiptURL.path, 0o600),
            0
        )
        let closureCalls = LockedCounter()
        let plyValidations = LockedCounter()
        var operations = PublishedResultPairOperations.system()
        operations.willValidatePly = { _ in plyValidations.increment() }

        XCTAssertThrowsError(try PublishedResultPairStore.commitReceiptBoundStateIf(
            projectPaths: fixture.paths,
            expectedGeneration: generation,
            expectedViewerReadySeconds: 117.75,
            operations: operations,
            afterValidation: { closureCalls.increment() }
        ))
        XCTAssertEqual(closureCalls.value, 0)
        XCTAssertEqual(plyValidations.value, 0)
    }

    func testCommitReceiptBoundStateRejectsSameInodePlyMutationWithoutValidation() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("mutated-bound-source.ply")
        let evidence = try writeSplat(at: source, x: 6)
        let published = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: makeReceipt(evidence: evidence),
            projectPaths: fixture.paths
        )
        let generation = try XCTUnwrap(published.generation)
        try mutateFirstFloatSameSize(at: fixture.paths.outputSplatURL)
        let closureCalls = LockedCounter()
        let plyValidations = LockedCounter()
        var operations = PublishedResultPairOperations.system()
        operations.willValidatePly = { _ in plyValidations.increment() }

        XCTAssertThrowsError(try PublishedResultPairStore.commitReceiptBoundStateIf(
            projectPaths: fixture.paths,
            expectedGeneration: generation,
            expectedViewerReadySeconds: 117.75,
            operations: operations,
            afterValidation: { closureCalls.increment() }
        ))
        XCTAssertEqual(closureCalls.value, 0)
        XCTAssertEqual(plyValidations.value, 0)
    }

    func testViewerTimingUpdateUsesExpectedGenerationWithoutPlyValidation() throws {
        let timing = try makeTimingFixture()
        defer { try? FileManager.default.removeItem(at: timing.root) }
        let predecessor = try XCTUnwrap(timing.published.generation)
        let plyValidations = LockedCounter()
        var operations = PublishedResultPairOperations.system()
        operations.willValidatePly = { _ in plyValidations.increment() }

        let committed = try PublishedResultPairStore.recordFirstViewerReadyTiming(
            142.25,
            expectedPublicationID: timing.receipt.publicationID,
            expectedGeneration: predecessor,
            projectPaths: timing.paths,
            operations: operations
        )

        XCTAssertEqual(
            committed.receipt.presentation.createToViewerReadySeconds,
            142.25
        )
        XCTAssertNotEqual(try XCTUnwrap(committed.generation), predecessor)
        XCTAssertEqual(plyValidations.value, 0)
    }

    func testViewerTimingUpdateRejectsMutatedExpectedGenerationWithoutPlyValidation() throws {
        let timing = try makeTimingFixture()
        defer { try? FileManager.default.removeItem(at: timing.root) }
        let predecessor = try XCTUnwrap(timing.published.generation)
        try mutateFirstFloatSameSize(at: timing.paths.outputSplatURL)
        let plyValidations = LockedCounter()
        var operations = PublishedResultPairOperations.system()
        operations.willValidatePly = { _ in plyValidations.increment() }

        XCTAssertThrowsError(try PublishedResultPairStore.recordFirstViewerReadyTiming(
            142.25,
            expectedPublicationID: timing.receipt.publicationID,
            expectedGeneration: predecessor,
            projectPaths: timing.paths,
            operations: operations
        ))
        XCTAssertEqual(plyValidations.value, 0)
    }

    func testStageTimingUpdatePreservesPublicationAndDoesNotRevalidatePly() throws {
        let timing = try makeTimingFixture()
        defer { try? FileManager.default.removeItem(at: timing.root) }
        let predecessor = try XCTUnwrap(timing.published.generation)
        let updatedTimings = timing.receipt.presentation.stageTimings + [
            StageTimingRecord(
                stage: .exportSplat,
                startedAt: Date(timeIntervalSince1970: 1_767_225_500),
                durationSeconds: 4.25
            ),
        ]
        let plyValidations = LockedCounter()
        var operations = PublishedResultPairOperations.system()
        operations.willValidatePly = { _ in plyValidations.increment() }

        let committed = try PublishedResultPairStore.recordStageTimings(
            updatedTimings,
            expectedGeneration: predecessor,
            projectPaths: timing.paths,
            operations: operations
        )

        XCTAssertEqual(committed.receipt.publicationID, timing.receipt.publicationID)
        XCTAssertEqual(committed.receipt.projectID, timing.receipt.projectID)
        XCTAssertEqual(committed.receipt.lineage, timing.receipt.lineage)
        XCTAssertEqual(committed.receipt.outputEvidence, timing.receipt.outputEvidence)
        XCTAssertEqual(committed.receipt.presentation.stageTimings, updatedTimings)
        XCTAssertNil(committed.receipt.presentation.createToViewerReadySeconds)
        XCTAssertNotEqual(try XCTUnwrap(committed.generation), predecessor)
        XCTAssertEqual(plyValidations.value, 0)
    }

    func testStageTimingUpdateAdvancesPublicationTimeToLatestStageCompletion() throws {
        let timing = try makeTimingFixture()
        defer { try? FileManager.default.removeItem(at: timing.root) }
        let predecessor = try XCTUnwrap(timing.published.generation)
        let exportStartedAt = timing.receipt.publishedAt.addingTimeInterval(10)
        let exportDuration = 4.25
        let completedAt = exportStartedAt.addingTimeInterval(exportDuration)
        let updatedTimings = timing.receipt.presentation.stageTimings + [
            StageTimingRecord(
                stage: .exportSplat,
                startedAt: exportStartedAt,
                durationSeconds: exportDuration
            ),
        ]
        let plyValidations = LockedCounter()
        var operations = PublishedResultPairOperations.system()
        operations.willValidatePly = { _ in plyValidations.increment() }

        let committed = try PublishedResultPairStore.recordStageTimings(
            updatedTimings,
            expectedGeneration: predecessor,
            projectPaths: timing.paths,
            operations: operations
        )

        XCTAssertEqual(committed.receipt.publicationID, timing.receipt.publicationID)
        XCTAssertEqual(committed.receipt.publishedAt, completedAt)
        XCTAssertEqual(committed.receipt.outputEvidence, timing.receipt.outputEvidence)
        XCTAssertEqual(committed.receipt.lineage, timing.receipt.lineage)
        XCTAssertEqual(committed.receipt.presentation.stageTimings, updatedTimings)
        XCTAssertEqual(plyValidations.value, 0)
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: timing.paths),
            .available(committed)
        )
    }

    func testBuildAuthorityWriteFailureRemovesExclusivePendingFile() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("authority-write-failure.ply")
        let evidence = try writeSplat(at: source, x: 6)
        var operations = PublishedResultPairOperations.system()
        operations.write = { _, _, _ in
            Darwin.__error().pointee = ENOSPC
            return -1
        }

        XCTAssertThrowsError(try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: makeReceipt(evidence: evidence),
            projectPaths: fixture.paths,
            operations: operations
        )) { error in
            guard case .persistence(_, let code) = error as? PublishedResultPairError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(code, ENOSPC)
        }
        XCTAssertFalse(try outputNames(in: fixture.paths).contains {
            $0.hasPrefix(".published-result-build-authority-")
                || $0.hasPrefix(".published-result-build-")
                || $0.hasPrefix(".published-result-tx-")
        })
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .unavailable(.missingPair)
        )
    }

    func testActiveAndInactiveBuildArePreservedAsConflict() throws {
        let fixture = try makeCrashFixture(phase: .created, hasPrevious: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let build = fixture.paths.outputURL.appendingPathComponent(
            ".published-result-build-11111111-aaaa-4aaa-8aaa-111111111111",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: build,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(Darwin.chmod(build.path, 0o700), 0)

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .conflict(.pendingTransaction)
        )
        XCTAssertEqual(activeTransactionURLs(in: fixture.paths).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: build.path))
    }

    func testFirstPublicationCrashMatrixRemovesOnlyPartialCanonicalFiles() throws {
        let phases: [PublishedResultPairJournalPhase] = [
            .created, .prepared, .newPlyInstalled, .receiptCommitted, .validated,
        ]
        for phase in phases {
            let fixture = try makeCrashFixture(phase: phase, hasPrevious: false)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            if phase.rawValue < PublishedResultPairJournalPhase.receiptCommitted.rawValue {
                XCTAssertEqual(
                    try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
                    .unavailable(.missingPair),
                    "Phase: \(phase)"
                )
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: fixture.paths.outputSplatURL.path
                ))
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: fixture.paths.outputSplatReceiptURL.path
                ))
            } else {
                XCTAssertEqual(
                    try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
                    .available(try XCTUnwrap(fixture.next)),
                    "Phase: \(phase)"
                )
            }
            XCTAssertEqual(
                try transactionPayloadBytes(in: fixture.paths),
                0,
                "Phase: \(phase)"
            )
        }
    }

    func testInvalidReceiptCommittedPairRollsBackToValidatedPreviousPair() throws {
        let fixture = try makeCrashFixture(phase: .receiptCommitted, hasPrevious: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try mutateFirstFloatSameSize(at: fixture.paths.outputSplatURL)

        do {
            try PublishedResultPairStore.reconcile(projectPaths: fixture.paths)
        } catch {
            XCTFail("Tampered committed reconciliation failed: \(error)")
        }

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(try XCTUnwrap(fixture.previous))
        )
    }

    func testReconcileCompletesRollbackInterruptedAfterPreviousPlyRestore() throws {
        let fixture = try makeCrashFixture(phase: .receiptCommitted, hasPrevious: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transaction = try XCTUnwrap(activeTransactionURLs(in: fixture.paths).first)
        try FileManager.default.moveItem(
            at: fixture.paths.outputSplatReceiptURL,
            to: transaction.appendingPathComponent("new-receipt.json")
        )
        try FileManager.default.moveItem(
            at: fixture.paths.outputSplatURL,
            to: transaction.appendingPathComponent("new.ply")
        )
        try FileManager.default.moveItem(
            at: transaction.appendingPathComponent("old.ply"),
            to: fixture.paths.outputSplatURL
        )

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(try XCTUnwrap(fixture.previous))
        )
        XCTAssertTrue(activeTransactionURLs(in: fixture.paths).isEmpty)
        XCTAssertEqual(try transactionPayloadBytes(in: fixture.paths), 0)
    }

    func testRecoveryRejectsRestoredPreviousPlyMutatedWithRestoredModificationTime() throws {
        let fixture = try makeCrashFixture(phase: .receiptCommitted, hasPrevious: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transaction = try XCTUnwrap(activeTransactionURLs(in: fixture.paths).first)
        try FileManager.default.moveItem(
            at: fixture.paths.outputSplatReceiptURL,
            to: transaction.appendingPathComponent("new-receipt.json")
        )
        try FileManager.default.moveItem(
            at: fixture.paths.outputSplatURL,
            to: transaction.appendingPathComponent("new.ply")
        )
        try FileManager.default.moveItem(
            at: transaction.appendingPathComponent("old.ply"),
            to: fixture.paths.outputSplatURL
        )

        let system = PublishedResultPairOperations.system()
        let mutation = LockedResult<Void>()
        var operations = system
        operations.renameExclusive = { sourceDirectory, source, destinationDirectory, destination in
            let result = system.renameExclusive(
                sourceDirectory,
                source,
                destinationDirectory,
                destination
            )
            if result == 0,
               source == "old-receipt.json",
               destination == "splat_receipt.json" {
                mutation.capture {
                    try mutatePublishedPairTestPlyRestoringTimes(
                        at: fixture.paths.outputSplatURL
                    )
                }
            }
            return result
        }

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(
                projectPaths: fixture.paths,
                operations: operations
            ),
            .conflict(.pendingTransaction)
        )
        XCTAssertNoThrow(try mutation.get())
        XCTAssertFalse(activeTransactionURLs(in: fixture.paths).isEmpty)
    }

    func testMalformedJournalAndUnknownTransactionEntryArePreservedAsConflict() throws {
        for mutation in ["journal", "unknown"] {
            let fixture = try makeCrashFixture(phase: .created, hasPrevious: true)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let transaction = try XCTUnwrap(activeTransactionURLs(in: fixture.paths).first)
            if mutation == "journal" {
                let journal = transaction.appendingPathComponent(
                    PublishedResultPairJournalPhase.created.leaf
                )
                var object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: journal))
                        as? [String: Any]
                )
                object["unexpected"] = true
                try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
                    .write(to: journal)
                XCTAssertEqual(Darwin.chmod(journal.path, 0o600), 0)
            } else {
                let foreign = transaction.appendingPathComponent("foreign.bin")
                try Data("preserve-me".utf8).write(to: foreign)
                XCTAssertEqual(Darwin.chmod(foreign.path, 0o600), 0)
            }

            XCTAssertEqual(
                try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
                .conflict(.pendingTransaction)
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.path))
            if mutation == "unknown" {
                XCTAssertEqual(
                    try Data(contentsOf: transaction.appendingPathComponent("foreign.bin")),
                    Data("preserve-me".utf8)
                )
            }
        }
    }

    func testUnsafeHistoricalJournalIdentityIsPreservedAsConflict() throws {
        let fixture = try makeCrashFixture(phase: .receiptCommitted, hasPrevious: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transaction = try XCTUnwrap(activeTransactionURLs(in: fixture.paths).first)
        let journal = transaction.appendingPathComponent(
            PublishedResultPairJournalPhase.prepared.leaf
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: journal))
                as? [String: Any]
        )
        var ownedFiles = try XCTUnwrap(object["ownedFiles"] as? [String: Any])
        var newPly = try XCTUnwrap(ownedFiles["new.ply"] as? [String: Any])
        newPly["mode"] = Int(S_IFREG | 0o644)
        ownedFiles["new.ply"] = newPly
        object["ownedFiles"] = ownedFiles
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: journal)
        XCTAssertEqual(Darwin.chmod(journal.path, 0o600), 0)

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .conflict(.pendingTransaction)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.path))
    }

    func testCanonicalPairRejectsSymlinksHardlinksFifosAndUnsafeModes() throws {
        enum Mutation: CaseIterable { case symlink, hardlink, fifo, mode, directory }
        for member in ["ply", "receipt"] {
            for mutation in Mutation.allCases {
                let fixture = try makeProject()
                defer { try? FileManager.default.removeItem(at: fixture.root) }
                let source = fixture.root.appendingPathComponent("source.ply")
                let evidence = try writeSplat(at: source, x: 9)
                _ = try PublishedResultPairStore.publish(
                    sourceURL: source,
                    receipt: makeReceipt(evidence: evidence),
                    projectPaths: fixture.paths
                )
                let target = member == "ply"
                    ? fixture.paths.outputSplatURL
                    : fixture.paths.outputSplatReceiptURL
                switch mutation {
                case .symlink:
                    let saved = target.appendingPathExtension("saved")
                    try FileManager.default.moveItem(at: target, to: saved)
                    try FileManager.default.createSymbolicLink(
                        at: target,
                        withDestinationURL: saved
                    )
                case .hardlink:
                    XCTAssertEqual(
                        Darwin.link(
                            target.path,
                            target.appendingPathExtension("link").path
                        ),
                        0
                    )
                case .fifo:
                    try FileManager.default.removeItem(at: target)
                    XCTAssertEqual(Darwin.mkfifo(target.path, 0o600), 0)
                case .mode:
                    XCTAssertEqual(Darwin.chmod(target.path, 0o644), 0)
                case .directory:
                    try FileManager.default.removeItem(at: target)
                    try FileManager.default.createDirectory(
                        at: target,
                        withIntermediateDirectories: false
                    )
                    XCTAssertEqual(Darwin.chmod(target.path, 0o700), 0)
                }
                XCTAssertEqual(
                    try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
                    .unavailable(.unsafePair),
                    "Member \(member), mutation \(mutation)"
                )
            }
        }
    }

    func testReceiptEvidenceMismatchAndTamperNeverAuthorizePly() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("source.ply")
        let evidence = try writeSplat(at: source, x: 1)
        let result = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: makeReceipt(evidence: evidence),
            projectPaths: fixture.paths
        )
        let wrongEvidence = ValidatedPlyArtifactEvidence(
            byteCount: evidence.byteCount,
            vertexCount: evidence.vertexCount,
            format: evidence.format,
            sha256: "0" + evidence.sha256.dropFirst(),
            sceneBounds: evidence.sceneBounds
        )
        try PublishedSplatReceiptStore.encode(makeReceipt(
            evidence: wrongEvidence,
            publicationID: result.receipt.publicationID
        )).write(to: fixture.paths.outputSplatReceiptURL)
        XCTAssertEqual(Darwin.chmod(fixture.paths.outputSplatReceiptURL.path, 0o600), 0)

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .unavailable(.evidenceMismatch)
        )
    }

    func testInjectedWriteSyncAndRenameFailuresRollbackWithoutLosingOldPair() throws {
        enum FailurePoint: CaseIterable {
            case write, fileSync, syncAfterOldMove, receiptRename
        }
        for point in FailurePoint.allCases {
            let fixture = try makeProject()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let oldSource = fixture.root.appendingPathComponent("old.ply")
            let newSource = fixture.root.appendingPathComponent("new.ply")
            let oldEvidence = try writeSplat(at: oldSource, x: 2)
            let newEvidence = try writeSplat(at: newSource, x: 3)
            let old = try PublishedResultPairStore.publish(
                sourceURL: oldSource,
                receipt: makeReceipt(evidence: oldEvidence),
                projectPaths: fixture.paths
            )
            let oldPlyBytes = try Data(contentsOf: fixture.paths.outputSplatURL)
            let oldReceiptBytes = try Data(
                contentsOf: fixture.paths.outputSplatReceiptURL
            )
            let system = PublishedResultPairOperations.system()
            var operations = system
            let gate = OneShotGate()
            switch point {
            case .write:
                operations.write = { _, _, _ in
                    Darwin.__error().pointee = ENOSPC
                    return -1
                }
            case .fileSync:
                operations.didReachCheckpoint = { checkpoint in
                    if checkpoint == .transactionCreated { gate.arm() }
                }
                operations.synchronizeFile = { descriptor in
                    if gate.consume() {
                        Darwin.__error().pointee = ENOSPC
                        return -1
                    }
                    return system.synchronizeFile(descriptor)
                }
            case .syncAfterOldMove:
                operations.didReachCheckpoint = { checkpoint in
                    if checkpoint == .previousPlyMoved { gate.arm() }
                }
                operations.synchronizeDirectory = { descriptor in
                    if gate.consume() {
                        Darwin.__error().pointee = ENOSPC
                        return -1
                    }
                    return system.synchronizeDirectory(descriptor)
                }
            case .receiptRename:
                operations.renameExclusive = { sourceDirectory, source, destinationDirectory, destination in
                    if source == "new-receipt.json", destination == "splat_receipt.json" {
                        Darwin.__error().pointee = ENOSPC
                        return -1
                    }
                    return system.renameExclusive(
                        sourceDirectory,
                        source,
                        destinationDirectory,
                        destination
                    )
                }
            }

            XCTAssertThrowsError(
                try PublishedResultPairStore.publish(
                    sourceURL: newSource,
                    receipt: makeReceipt(
                        evidence: newEvidence,
                        publicationID: UUID()
                    ),
                    projectPaths: fixture.paths,
                    operations: operations
                ),
                "Failure point: \(point)"
            )
            if point == .write {
                // Creation binds the exclusive placeholder before its first
                // write, so a partial write can remove only that exact inode
                // and leave the previously published pair authoritative.
                XCTAssertEqual(
                    try Data(contentsOf: fixture.paths.outputSplatURL),
                    oldPlyBytes
                )
                XCTAssertEqual(
                    try Data(contentsOf: fixture.paths.outputSplatReceiptURL),
                    oldReceiptBytes
                )
                XCTAssertFalse(try outputNames(in: fixture.paths).contains {
                    $0.hasPrefix(".published-result-build-authority-")
                        || $0.hasPrefix(".published-result-tx-")
                        || $0.hasPrefix(".published-result-build-")
                })
            }
            XCTAssertEqual(
                try PublishedResultPairStore.resolve(
                    projectPaths: fixture.paths
                ),
                .available(old),
                "Failure point: \(point)"
            )
            XCTAssertEqual(
                try transactionPayloadBytes(in: fixture.paths),
                0,
                "Failure point: \(point)"
            )
        }
    }

    func testDurableReceiptCommitWinsWhenLaterJournalSyncFails() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldSource = fixture.root.appendingPathComponent("old.ply")
        let newSource = fixture.root.appendingPathComponent("new.ply")
        let oldEvidence = try writeSplat(at: oldSource, x: 4)
        let newEvidence = try writeSplat(at: newSource, x: 5)
        _ = try PublishedResultPairStore.publish(
            sourceURL: oldSource,
            receipt: makeReceipt(evidence: oldEvidence),
            projectPaths: fixture.paths
        )
        let newReceipt = makeReceipt(evidence: newEvidence, publicationID: UUID())
        let system = PublishedResultPairOperations.system()
        let gate = OneShotGate()
        var operations = system
        operations.renameExclusive = { sourceDirectory, source, destinationDirectory, destination in
            let result = system.renameExclusive(
                sourceDirectory,
                source,
                destinationDirectory,
                destination
            )
            if result == 0,
               source == "new-receipt.json",
               destination == "splat_receipt.json" {
                gate.arm()
            }
            return result
        }
        operations.synchronizeFile = { descriptor in
            if gate.consume() {
                Darwin.__error().pointee = ENOSPC
                return -1
            }
            return system.synchronizeFile(descriptor)
        }

        let new = try PublishedResultPairStore.publish(
            sourceURL: newSource,
            receipt: newReceipt,
            projectPaths: fixture.paths,
            operations: operations
        )
        XCTAssertEqual(new.receipt.publicationID, newReceipt.publicationID)
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(new)
        )
    }

    func testCancellationDuringStreamingLeavesTrainingSourceAndOldPairIntact() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldSource = fixture.root.appendingPathComponent("old.ply")
        let largeSource = fixture.root.appendingPathComponent("large.ply")
        let oldEvidence = try writeSplat(at: oldSource, x: 6)
        let old = try PublishedResultPairStore.publish(
            sourceURL: oldSource,
            receipt: makeReceipt(evidence: oldEvidence),
            projectPaths: fixture.paths
        )
        try TestFileBuilder.writeMinimalPly(at: largeSource, vertexCount: 60_000)
        XCTAssertEqual(Darwin.chmod(largeSource.path, 0o600), 0)
        let largeEvidence = try ProjectArtifactValidator.validatedPlyEvidence(at: largeSource)
        let cancellation = LockedFlag()
        let system = PublishedResultPairOperations.system()
        var operations = system
        operations.readAt = { descriptor, bytes, count, offset in
            let result = system.readAt(descriptor, bytes, count, offset)
            if result > 0 { cancellation.set() }
            return result
        }

        XCTAssertThrowsError(
            try PublishedResultPairStore.publish(
                sourceURL: largeSource,
                receipt: makeReceipt(evidence: largeEvidence, publicationID: UUID()),
                projectPaths: fixture.paths,
                operations: operations,
                shouldCancel: { cancellation.value }
            )
        ) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: largeSource.path))
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(old)
        )
        XCTAssertEqual(try transactionPayloadBytes(in: fixture.paths), 0)
    }

    func testConcurrentReaderWaitsForWriterAndSeesOnlyCommittedNewPair() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldSource = fixture.root.appendingPathComponent("old.ply")
        let newSource = fixture.root.appendingPathComponent("new.ply")
        let oldEvidence = try writeSplat(at: oldSource, x: 7)
        let newEvidence = try writeSplat(at: newSource, x: 8)
        _ = try PublishedResultPairStore.publish(
            sourceURL: oldSource,
            receipt: makeReceipt(evidence: oldEvidence),
            projectPaths: fixture.paths
        )
        let newReceipt = makeReceipt(evidence: newEvidence, publicationID: UUID())
        let writerPaused = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let readerWaiting = DispatchSemaphore(value: 0)
        let readerAcquired = DispatchSemaphore(value: 0)
        let writerDone = DispatchSemaphore(value: 0)
        let readerDone = DispatchSemaphore(value: 0)
        let writerResult = LockedResult<ValidatedPublishedResult>()
        let readerResult = LockedResult<PublishedResultAvailability>()

        var writerOperationsBuilder = PublishedResultPairOperations.system()
        writerOperationsBuilder.didReachCheckpoint = { checkpoint in
            if checkpoint == .previousPairMoved {
                writerPaused.signal()
                releaseWriter.wait()
            }
        }
        let writerOperations = writerOperationsBuilder
        DispatchQueue.global(qos: .userInitiated).async {
            writerResult.capture {
                try PublishedResultPairStore.publish(
                    sourceURL: newSource,
                    receipt: newReceipt,
                    projectPaths: fixture.paths,
                    operations: writerOperations
                )
            }
            writerDone.signal()
        }
        XCTAssertEqual(writerPaused.wait(timeout: .now() + 5), .success)

        var readerOperationsBuilder = PublishedResultPairOperations.system()
        readerOperationsBuilder.didReachCheckpoint = { checkpoint in
            if checkpoint == .lockWaitStarted { readerWaiting.signal() }
            if checkpoint == .lockAcquired { readerAcquired.signal() }
        }
        let readerOperations = readerOperationsBuilder
        DispatchQueue.global(qos: .userInitiated).async {
            readerResult.capture {
                try PublishedResultPairStore.resolve(
                    projectPaths: fixture.paths,
                    operations: readerOperations
                )
            }
            readerDone.signal()
        }
        XCTAssertEqual(readerWaiting.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(readerAcquired.wait(timeout: .now()), .timedOut)
        releaseWriter.signal()
        XCTAssertEqual(writerDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(readerDone.wait(timeout: .now() + 5), .success)

        let new = try writerResult.get()
        XCTAssertEqual(try readerResult.get(), .available(new))
    }

    func testCleanupDirectoryReplacementIsPreservedAndSurfaced() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldSource = fixture.root.appendingPathComponent("old.ply")
        let newSource = fixture.root.appendingPathComponent("new.ply")
        let oldEvidence = try writeSplat(at: oldSource, x: 9)
        let newEvidence = try writeSplat(at: newSource, x: 1)
        _ = try PublishedResultPairStore.publish(
            sourceURL: oldSource,
            receipt: makeReceipt(evidence: oldEvidence),
            projectPaths: fixture.paths
        )
        let foreignBytes = Data("foreign-cleanup-entry".utf8)
        let replacedTransaction = LockedURL()
        let outputURL = fixture.paths.outputURL
        var operations = PublishedResultPairOperations.system()
        operations.didReachCheckpoint = { checkpoint in
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: outputURL,
                includingPropertiesForKeys: nil
            )) ?? []
            guard checkpoint == .canonicalPairValidated,
                  let transaction = entries.first(where: {
                      $0.lastPathComponent.hasPrefix(".published-result-tx-")
                  }) else {
                return
            }
            let displaced = fixture.paths.outputURL.appendingPathComponent(
                ".cleanup-race-original-\(UUID().uuidString)"
            )
            do {
                try FileManager.default.moveItem(at: transaction, to: displaced)
                try FileManager.default.createDirectory(
                    at: transaction,
                    withIntermediateDirectories: false
                )
                _ = Darwin.chmod(transaction.path, 0o700)
                let foreign = transaction.appendingPathComponent("foreign.bin")
                try foreignBytes.write(to: foreign)
                _ = Darwin.chmod(foreign.path, 0o600)
                replacedTransaction.set(transaction)
            } catch {
                XCTFail("Could not install cleanup race fixture: \(error)")
            }
        }

        XCTAssertThrowsError(
            try PublishedResultPairStore.publish(
                sourceURL: newSource,
                receipt: makeReceipt(evidence: newEvidence, publicationID: UUID()),
                projectPaths: fixture.paths,
                operations: operations
            )
        ) { error in
            guard case .publicationConflict = error as? PublishedResultPairError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        let foreignDirectory = try XCTUnwrap(replacedTransaction.value)
        XCTAssertEqual(
            try Data(contentsOf: foreignDirectory.appendingPathComponent("foreign.bin")),
            foreignBytes
        )
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .conflict(.pendingTransaction)
        )
        XCTAssertEqual(
            try Data(contentsOf: foreignDirectory.appendingPathComponent("foreign.bin")),
            foreignBytes
        )
    }

    func testSourceAndStagedCandidateMutationFailBeforePreviousPairMoves() throws {
        enum Mutation: CaseIterable { case source, stagedCandidate }

        for mutation in Mutation.allCases {
            let fixture = try makeProject()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let oldSource = fixture.root.appendingPathComponent("old.ply")
            let newSource = fixture.root.appendingPathComponent("new.ply")
            let oldEvidence = try writeSplat(at: oldSource, x: 2)
            let newEvidence = try writeSplat(at: newSource, x: 3)
            let old = try PublishedResultPairStore.publish(
                sourceURL: oldSource,
                receipt: makeReceipt(evidence: oldEvidence),
                projectPaths: fixture.paths
            )
            let checkpoints = LockedValues<PublishedResultPairCheckpoint>()
            let mutationResult = LockedResult<Void>()
            var operations = PublishedResultPairOperations.system()
            operations.didReachCheckpoint = { checkpoint in
                checkpoints.append(checkpoint)
                switch (mutation, checkpoint) {
                case (.source, .newPlyDurable):
                    mutationResult.capture {
                        try mutatePublishedPairTestPly(at: newSource)
                    }
                case (.stagedCandidate, .prepared):
                    mutationResult.capture {
                        guard let transaction = publishedPairTestTransactions(
                            in: fixture.paths
                        ).first else {
                            throw CocoaError(.fileNoSuchFile)
                        }
                        try mutatePublishedPairTestPly(
                            at: transaction.appendingPathComponent("new.ply")
                        )
                    }
                default:
                    break
                }
            }

            XCTAssertThrowsError(
                try PublishedResultPairStore.publish(
                    sourceURL: newSource,
                    receipt: makeReceipt(evidence: newEvidence, publicationID: UUID()),
                    projectPaths: fixture.paths,
                    operations: operations
                ),
                "Mutation: \(mutation)"
            ) { error in
                XCTAssertEqual(
                    error as? PublishedResultPairError,
                    .invalidSource,
                    "Mutation: \(mutation)"
                )
            }
            XCTAssertNoThrow(try mutationResult.get(), "Mutation: \(mutation)")
            XCTAssertFalse(
                checkpoints.values.contains(.previousPlyMoved),
                "Mutation: \(mutation)"
            )
            XCTAssertEqual(
                try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
                .available(old),
                "Mutation: \(mutation)"
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: newSource.path))
        }
    }

    func testPublicationRejectsSourceThroughIntermediateDirectorySymlink() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let realDirectory = fixture.root.appendingPathComponent(
            "real-source",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: realDirectory,
            withIntermediateDirectories: false
        )
        let source = realDirectory.appendingPathComponent("source.ply")
        let evidence = try writeSplat(at: source, x: 3)
        let linkedDirectory = fixture.root.appendingPathComponent(
            "linked-source",
            isDirectory: true
        )
        XCTAssertEqual(
            Darwin.symlink(realDirectory.path, linkedDirectory.path),
            0
        )

        XCTAssertThrowsError(try PublishedResultPairStore.publish(
            sourceURL: linkedDirectory.appendingPathComponent("source.ply"),
            receipt: makeReceipt(evidence: evidence),
            projectPaths: fixture.paths
        )) {
            XCTAssertEqual($0 as? PublishedResultPairError, .invalidSource)
        }
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .unavailable(.missingPair)
        )
    }

    func testSourceParentReplacementWithSymlinkFailsBeforePreviousPairMoves() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldSource = fixture.root.appendingPathComponent("old.ply")
        let oldEvidence = try writeSplat(at: oldSource, x: 4)
        let old = try PublishedResultPairStore.publish(
            sourceURL: oldSource,
            receipt: makeReceipt(evidence: oldEvidence),
            projectPaths: fixture.paths
        )
        let trainingDirectory = fixture.root.appendingPathComponent(
            "Training",
            isDirectory: true
        )
        let sourceDirectory = trainingDirectory.appendingPathComponent(
            "msplat",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sourceDirectory,
            withIntermediateDirectories: true
        )
        let newSource = sourceDirectory.appendingPathComponent("splat.ply")
        let newEvidence = try writeSplat(at: newSource, x: 5)
        let displacedDirectory = fixture.root.appendingPathComponent(
            "held-msplat",
            isDirectory: true
        )
        let mutation = LockedResult<Void>()
        let checkpoints = LockedValues<PublishedResultPairCheckpoint>()
        var operations = PublishedResultPairOperations.system()
        operations.didReachCheckpoint = { checkpoint in
            checkpoints.append(checkpoint)
            guard checkpoint == .newPlyDurable else { return }
            mutation.capture {
                try FileManager.default.moveItem(
                    at: sourceDirectory,
                    to: displacedDirectory
                )
                guard Darwin.symlink(
                    displacedDirectory.path,
                    sourceDirectory.path
                ) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
            }
        }

        XCTAssertThrowsError(try PublishedResultPairStore.publish(
            sourceURL: newSource,
            receipt: makeReceipt(evidence: newEvidence, publicationID: UUID()),
            projectPaths: fixture.paths,
            operations: operations
        )) {
            XCTAssertEqual($0 as? PublishedResultPairError, .invalidSource)
        }
        XCTAssertNoThrow(try mutation.get())
        XCTAssertFalse(checkpoints.values.contains(.previousPlyMoved))
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(old)
        )
    }

    func testPreviousPairMutationDuringStagingAbortsBeforePreservation() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldSource = fixture.root.appendingPathComponent("old.ply")
        let newSource = fixture.root.appendingPathComponent("new.ply")
        let oldEvidence = try writeSplat(at: oldSource, x: 3)
        let newEvidence = try writeSplat(at: newSource, x: 4)
        _ = try PublishedResultPairStore.publish(
            sourceURL: oldSource,
            receipt: makeReceipt(evidence: oldEvidence),
            projectPaths: fixture.paths
        )
        let mutationResult = LockedResult<Void>()
        let checkpoints = LockedValues<PublishedResultPairCheckpoint>()
        var operations = PublishedResultPairOperations.system()
        operations.didReachCheckpoint = { checkpoint in
            checkpoints.append(checkpoint)
            guard checkpoint == .prepared else { return }
            mutationResult.capture {
                try mutatePublishedPairTestPly(at: fixture.paths.outputSplatURL)
            }
        }

        XCTAssertThrowsError(
            try PublishedResultPairStore.publish(
                sourceURL: newSource,
                receipt: makeReceipt(evidence: newEvidence, publicationID: UUID()),
                projectPaths: fixture.paths,
                operations: operations
            )
        ) { error in
            guard case .publicationConflict = error as? PublishedResultPairError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertNoThrow(try mutationResult.get())
        XCTAssertFalse(checkpoints.values.contains(.previousPlyMoved))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.paths.outputSplatURL.path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.paths.outputSplatReceiptURL.path
        ))
        XCTAssertEqual(activeTransactionURLs(in: fixture.paths).count, 1)
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .conflict(.pendingTransaction)
        )
    }

    func testInvalidFirstPublicationAfterReceiptCommitQuarantinesCanonicalPair() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("source.ply")
        let evidence = try writeSplat(at: source, x: 4)
        let mutationResult = LockedResult<Void>()
        var operations = PublishedResultPairOperations.system()
        operations.didReachCheckpoint = { checkpoint in
            guard checkpoint == .newReceiptInstalled else { return }
            mutationResult.capture {
                try mutatePublishedPairTestPly(at: fixture.paths.outputSplatURL)
            }
        }

        XCTAssertThrowsError(
            try PublishedResultPairStore.publish(
                sourceURL: source,
                receipt: makeReceipt(evidence: evidence),
                projectPaths: fixture.paths,
                operations: operations
            )
        )
        XCTAssertNoThrow(try mutationResult.get())
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .unavailable(.missingPair)
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.outputSplatURL.path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.outputSplatReceiptURL.path
        ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testLockRejectsSymlinkHardlinkFifoDirectoryAndUnsafeMode() throws {
        enum Mutation: CaseIterable { case symlink, hardlink, fifo, directory, mode }

        for mutation in Mutation.allCases {
            let fixture = try makeProject()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            _ = try PublishedResultPairStore.resolve(projectPaths: fixture.paths)
            let lock = fixture.paths.publishedResultLockURL
            switch mutation {
            case .symlink:
                let saved = lock.appendingPathExtension("saved")
                try FileManager.default.moveItem(at: lock, to: saved)
                try FileManager.default.createSymbolicLink(
                    at: lock,
                    withDestinationURL: saved
                )
            case .hardlink:
                XCTAssertEqual(
                    Darwin.link(lock.path, lock.appendingPathExtension("link").path),
                    0
                )
            case .fifo:
                try FileManager.default.removeItem(at: lock)
                XCTAssertEqual(Darwin.mkfifo(lock.path, 0o600), 0)
            case .directory:
                try FileManager.default.removeItem(at: lock)
                try FileManager.default.createDirectory(
                    at: lock,
                    withIntermediateDirectories: false
                )
                XCTAssertEqual(Darwin.chmod(lock.path, 0o700), 0)
            case .mode:
                XCTAssertEqual(Darwin.chmod(lock.path, 0o644), 0)
            }

            XCTAssertThrowsError(
                try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
                "Mutation: \(mutation)"
            ) { error in
                XCTAssertEqual(
                    error as? PublishedResultPairError,
                    .unsafeOutput,
                    "Mutation: \(mutation)"
                )
            }
        }
    }

    func testOutputAndLockPathReplacementAfterLockAcquisitionFailClosed() throws {
        enum Mutation: CaseIterable { case outputDirectory, lockPath }

        for mutation in Mutation.allCases {
            let fixture = try makeProject()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let mutationResult = LockedResult<Void>()
            let foreignBytes = Data("foreign-boundary".utf8)
            var operations = PublishedResultPairOperations.system()
            operations.didReachCheckpoint = { checkpoint in
                guard checkpoint == .lockAcquired else { return }
                mutationResult.capture {
                    switch mutation {
                    case .outputDirectory:
                        let displaced = fixture.root.appendingPathComponent(
                            "displaced-output",
                            isDirectory: true
                        )
                        try FileManager.default.moveItem(
                            at: fixture.paths.outputURL,
                            to: displaced
                        )
                        try FileManager.default.createDirectory(
                            at: fixture.paths.outputURL,
                            withIntermediateDirectories: false
                        )
                        try foreignBytes.write(
                            to: fixture.paths.outputURL.appendingPathComponent("foreign.bin")
                        )
                    case .lockPath:
                        let saved = fixture.paths.publishedResultLockURL
                            .appendingPathExtension("saved")
                        try FileManager.default.moveItem(
                            at: fixture.paths.publishedResultLockURL,
                            to: saved
                        )
                        try Data().write(to: fixture.paths.publishedResultLockURL)
                        guard Darwin.chmod(
                            fixture.paths.publishedResultLockURL.path,
                            0o600
                        ) == 0 else {
                            throw POSIXError(.init(rawValue: errno) ?? .EIO)
                        }
                    }
                }
            }

            XCTAssertThrowsError(
                try PublishedResultPairStore.resolve(
                    projectPaths: fixture.paths,
                    operations: operations
                ),
                "Mutation: \(mutation)"
            ) { error in
                XCTAssertEqual(
                    error as? PublishedResultPairError,
                    .unsafeOutput,
                    "Mutation: \(mutation)"
                )
            }
            XCTAssertNoThrow(try mutationResult.get(), "Mutation: \(mutation)")
            switch mutation {
            case .outputDirectory:
                XCTAssertEqual(
                    try Data(contentsOf: fixture.paths.outputURL
                        .appendingPathComponent("foreign.bin")),
                    foreignBytes
                )
            case .lockPath:
                XCTAssertTrue(FileManager.default.fileExists(
                    atPath: fixture.paths.publishedResultLockURL.path
                ))
            }
        }
    }

    func testLockReplacementDuringPairValidationNeverReturnsAuthority() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("source.ply")
        let evidence = try writeSplat(at: source, x: 8)
        _ = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: makeReceipt(evidence: evidence),
            projectPaths: fixture.paths
        )
        let replacementResult = LockedResult<Void>()
        var operations = PublishedResultPairOperations.system()
        operations.willValidatePly = { label in
            guard label == "splat.ply" else { return }
            replacementResult.capture {
                let saved = fixture.paths.publishedResultLockURL
                    .appendingPathExtension("during-validation")
                try FileManager.default.moveItem(
                    at: fixture.paths.publishedResultLockURL,
                    to: saved
                )
                try Data().write(to: fixture.paths.publishedResultLockURL)
                guard Darwin.chmod(
                    fixture.paths.publishedResultLockURL.path,
                    0o600
                ) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
            }
        }

        XCTAssertThrowsError(
            try PublishedResultPairStore.resolve(
                projectPaths: fixture.paths,
                operations: operations
            )
        ) { error in
            XCTAssertEqual(error as? PublishedResultPairError, .unsafeOutput)
        }
        XCTAssertNoThrow(try replacementResult.get())
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.paths.outputSplatURL.path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.paths.outputSplatReceiptURL.path
        ))
    }

    func testUnsafeTransactionEntriesArePreservedAndNeverReconciled() throws {
        enum Mutation: CaseIterable { case journalSymlink, journalHardlink, journalFifo
            case journalMode, transactionMode }

        for mutation in Mutation.allCases {
            let fixture = try makeCrashFixture(phase: .created, hasPrevious: true)
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let transaction = try XCTUnwrap(activeTransactionURLs(in: fixture.paths).first)
            let journal = transaction.appendingPathComponent(
                PublishedResultPairJournalPhase.created.leaf
            )
            switch mutation {
            case .journalSymlink:
                let saved = journal.appendingPathExtension("saved")
                try FileManager.default.moveItem(at: journal, to: saved)
                try FileManager.default.createSymbolicLink(
                    at: journal,
                    withDestinationURL: saved
                )
            case .journalHardlink:
                XCTAssertEqual(
                    Darwin.link(journal.path, journal.appendingPathExtension("link").path),
                    0
                )
            case .journalFifo:
                try FileManager.default.removeItem(at: journal)
                XCTAssertEqual(Darwin.mkfifo(journal.path, 0o600), 0)
            case .journalMode:
                XCTAssertEqual(Darwin.chmod(journal.path, 0o644), 0)
            case .transactionMode:
                XCTAssertEqual(Darwin.chmod(transaction.path, 0o755), 0)
            }

            let availability = try PublishedResultPairStore.resolve(
                projectPaths: fixture.paths
            )
            guard case .conflict = availability else {
                return XCTFail("Mutation \(mutation) resolved as \(availability)")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.path))
        }
    }

    func testCleanupFileReplacementIsPreservedAsActiveConflict() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldSource = fixture.root.appendingPathComponent("old.ply")
        let newSource = fixture.root.appendingPathComponent("new.ply")
        let oldEvidence = try writeSplat(at: oldSource, x: 5)
        let newEvidence = try writeSplat(at: newSource, x: 6)
        _ = try PublishedResultPairStore.publish(
            sourceURL: oldSource,
            receipt: makeReceipt(evidence: oldEvidence),
            projectPaths: fixture.paths
        )
        let foreignBytes = Data("foreign-file-replacement".utf8)
        let replacementResult = LockedResult<Void>()
        var operations = PublishedResultPairOperations.system()
        operations.didReachCheckpoint = { checkpoint in
            guard checkpoint == .canonicalPairValidated,
                  let transaction = publishedPairTestTransactions(
                    in: fixture.paths
                  ).first else {
                return
            }
            let owned = transaction.appendingPathComponent("old.ply")
            let displaced = transaction.appendingPathComponent("displaced-old.ply")
            replacementResult.capture {
                try FileManager.default.moveItem(at: owned, to: displaced)
                try foreignBytes.write(to: owned)
                _ = Darwin.chmod(owned.path, 0o600)
            }
        }

        XCTAssertThrowsError(
            try PublishedResultPairStore.publish(
                sourceURL: newSource,
                receipt: makeReceipt(evidence: newEvidence, publicationID: UUID()),
                projectPaths: fixture.paths,
                operations: operations
            )
        ) { error in
            guard case .publicationConflict = error as? PublishedResultPairError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertNoThrow(try replacementResult.get())
        let active = try XCTUnwrap(activeTransactionURLs(in: fixture.paths).first)
        XCTAssertEqual(
            try Data(contentsOf: active.appendingPathComponent("old.ply")),
            foreignBytes
        )
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .conflict(.pendingTransaction)
        )
        XCTAssertEqual(
            try Data(contentsOf: active.appendingPathComponent("old.ply")),
            foreignBytes
        )
    }

    func testMultiplePendingTransactionsArePreservedAsConflict() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try PublishedResultPairStore.testCreateTransactionFixture(
            projectPaths: fixture.paths,
            transactionID: UUID(
                uuidString: "11111111-aaaa-4aaa-8aaa-111111111111"
            )!,
            publicationID: UUID(),
            previousPublicationID: nil
        )
        let second = fixture.paths.outputURL.appendingPathComponent(
            ".published-result-tx-22222222-bbbb-4bbb-8bbb-222222222222",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: second,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(Darwin.chmod(second.path, 0o700), 0)

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .conflict(.pendingTransaction)
        )
        XCTAssertEqual(activeTransactionURLs(in: fixture.paths).count, 2)
    }

    func testCommittedRecoveryRequiresExactJournaledCanonicalIdentities() throws {
        let fixture = try makeCrashFixture(
            phase: .receiptCommitted,
            hasPrevious: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transaction = try XCTUnwrap(activeTransactionURLs(in: fixture.paths).first)
        let displacedPly = fixture.root.appendingPathComponent("displaced-new.ply")
        let displacedReceipt = fixture.root.appendingPathComponent(
            "displaced-new-receipt.json"
        )
        try FileManager.default.moveItem(
            at: fixture.paths.outputSplatURL,
            to: displacedPly
        )
        try FileManager.default.moveItem(
            at: fixture.paths.outputSplatReceiptURL,
            to: displacedReceipt
        )

        let foreignSource = fixture.root.appendingPathComponent("foreign.ply")
        let foreignEvidence = try writeSplat(at: foreignSource, x: 9)
        try FileManager.default.copyItem(
            at: foreignSource,
            to: fixture.paths.outputSplatURL
        )
        XCTAssertEqual(Darwin.chmod(fixture.paths.outputSplatURL.path, 0o600), 0)
        let publicationID = try XCTUnwrap(fixture.next?.receipt.publicationID)
        try PublishedSplatReceiptStore.encode(makeReceipt(
            evidence: foreignEvidence,
            publicationID: publicationID
        )).write(to: fixture.paths.outputSplatReceiptURL)
        XCTAssertEqual(
            Darwin.chmod(fixture.paths.outputSplatReceiptURL.path, 0o600),
            0
        )

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .conflict(.pendingTransaction)
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: transaction.appendingPathComponent("old.ply").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: transaction.appendingPathComponent("old-receipt.json").path
        ))
    }

    func testHeldOldPlyDescriptorRemainsCompleteAfterReplacementCleanup() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldSource = fixture.root.appendingPathComponent("old.ply")
        let newSource = fixture.root.appendingPathComponent("new.ply")
        let oldEvidence = try writeSplat(at: oldSource, x: 3)
        let newEvidence = try writeSplat(at: newSource, x: 4)
        _ = try PublishedResultPairStore.publish(
            sourceURL: oldSource,
            receipt: makeReceipt(evidence: oldEvidence),
            projectPaths: fixture.paths
        )
        let reader = Darwin.open(
            fixture.paths.outputSplatURL.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(reader, 0)
        defer { Darwin.close(reader) }
        var before = stat()
        XCTAssertEqual(Darwin.fstat(reader, &before), 0)

        _ = try PublishedResultPairStore.publish(
            sourceURL: newSource,
            receipt: makeReceipt(evidence: newEvidence, publicationID: UUID()),
            projectPaths: fixture.paths
        )

        var after = stat()
        XCTAssertEqual(Darwin.fstat(reader, &after), 0)
        XCTAssertEqual(after.st_size, before.st_size)
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.pread(reader, &byte, 1, 0), 1)
        XCTAssertEqual(byte, UInt8(ascii: "p"))
    }

    func testRetireRenameThenSyncFailureIsRetriedWithoutFalseFailure() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldSource = fixture.root.appendingPathComponent("old.ply")
        let newSource = fixture.root.appendingPathComponent("new.ply")
        let oldEvidence = try writeSplat(at: oldSource, x: 3)
        let newEvidence = try writeSplat(at: newSource, x: 4)
        _ = try PublishedResultPairStore.publish(
            sourceURL: oldSource,
            receipt: makeReceipt(evidence: oldEvidence),
            projectPaths: fixture.paths
        )

        let system = PublishedResultPairOperations.system()
        let failNextSync = OneShotGate()
        var operations = system
        operations.renameExclusive = { sourceDirectory, source, destinationDirectory, destination in
            let result = system.renameExclusive(
                sourceDirectory,
                source,
                destinationDirectory,
                destination
            )
            if result == 0,
               source.hasPrefix(".published-result-tx-"),
               destination.hasPrefix(".published-result-retired-") {
                failNextSync.arm()
            }
            return result
        }
        operations.synchronizeDirectory = { descriptor in
            if failNextSync.consume() {
                Darwin.__error().pointee = ENOSPC
                return -1
            }
            return system.synchronizeDirectory(descriptor)
        }

        let published = try PublishedResultPairStore.publish(
            sourceURL: newSource,
            receipt: makeReceipt(evidence: newEvidence, publicationID: UUID()),
            projectPaths: fixture.paths,
            operations: operations
        )
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(published)
        )
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.outputURL.path
        )
        XCTAssertFalse(entries.contains {
            $0.hasPrefix(".published-result-tx-")
                || $0.hasPrefix(".published-result-retired-")
        })
    }

    func testRetiredCleanupResumesAfterAuthorityWasQuarantined() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldSource = fixture.root.appendingPathComponent("old.ply")
        let newSource = fixture.root.appendingPathComponent("new.ply")
        let oldEvidence = try writeSplat(at: oldSource, x: 3)
        let newEvidence = try writeSplat(at: newSource, x: 4)
        _ = try PublishedResultPairStore.publish(
            sourceURL: oldSource,
            receipt: makeReceipt(evidence: oldEvidence),
            projectPaths: fixture.paths
        )

        var operations = PublishedResultPairOperations.system()
        operations.willUnlinkQuarantinedEntry = { name in
            guard name == "cleanup-authorized.json" else { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINTR))
        }
        let newReceipt = makeReceipt(
            evidence: newEvidence,
            publicationID: UUID()
        )
        XCTAssertThrowsError(
            try PublishedResultPairStore.publish(
                sourceURL: newSource,
                receipt: newReceipt,
                projectPaths: fixture.paths,
                operations: operations
            )
        )

        let interrupted = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: fixture.paths.outputURL,
                includingPropertiesForKeys: nil
            ).first {
                $0.lastPathComponent.hasPrefix(".published-result-retired-")
            }
        )
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: interrupted.appendingPathComponent(
                ".cleanup-cleanup-authorized.json"
            ).path
        ))

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(ValidatedPublishedResult(
                receipt: newReceipt,
                outputURL: fixture.paths.outputSplatURL,
                outputEvidence: newEvidence
            ))
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: interrupted.path))
    }

    func testActiveCleanupAuthorityRejectsMismatchedIDsAndUnknownNestedKeys() throws {
        for mutation in ["publicationID", "nestedKey"] {
            let fixture = try makeProject()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let oldSource = fixture.root.appendingPathComponent("old.ply")
            let newSource = fixture.root.appendingPathComponent("new.ply")
            let oldEvidence = try writeSplat(at: oldSource, x: 3)
            let newEvidence = try writeSplat(at: newSource, x: 4)
            _ = try PublishedResultPairStore.publish(
                sourceURL: oldSource,
                receipt: makeReceipt(evidence: oldEvidence),
                projectPaths: fixture.paths
            )

            let system = PublishedResultPairOperations.system()
            var operations = system
            operations.renameExclusive = {
                sourceDirectory, source, destinationDirectory, destination in
                if source.hasPrefix(".published-result-tx-"),
                   destination.hasPrefix(".published-result-retired-") {
                    Darwin.__error().pointee = ENOSPC
                    return -1
                }
                return system.renameExclusive(
                    sourceDirectory,
                    source,
                    destinationDirectory,
                    destination
                )
            }
            XCTAssertThrowsError(try PublishedResultPairStore.publish(
                sourceURL: newSource,
                receipt: makeReceipt(evidence: newEvidence, publicationID: UUID()),
                projectPaths: fixture.paths,
                operations: operations
            ))

            let active = try XCTUnwrap(activeTransactionURLs(in: fixture.paths).first)
            let authority = active.appendingPathComponent("cleanup-authorized.json")
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: authority))
                    as? [String: Any]
            )
            if mutation == "publicationID" {
                object["publicationID"] = UUID().uuidString.lowercased()
            } else {
                var owned = try XCTUnwrap(object["ownedFiles"] as? [String: Any])
                let name = try XCTUnwrap(owned.keys.sorted().first)
                var identity = try XCTUnwrap(owned[name] as? [String: Any])
                identity["unexpected"] = true
                owned[name] = identity
                object["ownedFiles"] = owned
            }
            let tampered = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            let handle = try FileHandle(forWritingTo: authority)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: tampered)
            try handle.synchronize()
            try handle.close()

            XCTAssertEqual(
                try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
                .conflict(.pendingTransaction),
                "Mutation: \(mutation)"
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
        }
    }

    func testPartialCleanupAuthorizationWriteHealsAfterCommittedPair() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let oldSource = fixture.root.appendingPathComponent("old.ply")
        let newSource = fixture.root.appendingPathComponent("new.ply")
        let oldEvidence = try writeSplat(at: oldSource, x: 3)
        let newEvidence = try writeSplat(at: newSource, x: 4)
        _ = try PublishedResultPairStore.publish(
            sourceURL: oldSource,
            receipt: makeReceipt(evidence: oldEvidence),
            projectPaths: fixture.paths
        )

        let system = PublishedResultPairOperations.system()
        let fault = CleanupAuthorizationWriteFault()
        var operations = system
        operations.didReachCheckpoint = { checkpoint in
            if checkpoint == .canonicalPairValidated { fault.arm() }
        }
        operations.write = { descriptor, bytes, count in
            fault.write(
                descriptor: descriptor,
                bytes: bytes,
                count: count,
                system: system.write
            )
        }
        let newReceipt = makeReceipt(
            evidence: newEvidence,
            publicationID: UUID()
        )
        XCTAssertThrowsError(
            try PublishedResultPairStore.publish(
                sourceURL: newSource,
                receipt: newReceipt,
                projectPaths: fixture.paths,
                operations: operations
            )
        )

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(ValidatedPublishedResult(
                receipt: newReceipt,
                outputURL: fixture.paths.outputSplatURL,
                outputEvidence: newEvidence
            ))
        )
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.outputURL.path
        )
        XCTAssertFalse(entries.contains {
            $0.hasPrefix(".published-result-tx-")
                || $0.hasPrefix(".published-result-retired-")
        })
    }

    func testAmbiguousPartialCleanupAuthorityIsPreservedAsConflict() throws {
        let fixture = try makeCrashFixture(phase: .validated, hasPrevious: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let transactions = activeTransactionURLs(in: fixture.paths)
        XCTAssertEqual(transactions.count, 1)
        let transaction = try XCTUnwrap(transactions.first)
        let partial = transaction.appendingPathComponent(
            "cleanup-authorized.json.pending"
        )
        let partialBytes = Data("partial-unbound-authority".utf8)
        try partialBytes.write(to: partial)
        XCTAssertEqual(Darwin.chmod(partial.path, 0o600), 0)
        let canonicalPly = try Data(contentsOf: fixture.paths.outputSplatURL)
        let canonicalReceipt = try Data(
            contentsOf: fixture.paths.outputSplatReceiptURL
        )

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .conflict(.pendingTransaction)
        )
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .conflict(.pendingTransaction)
        )
        XCTAssertEqual(try Data(contentsOf: partial), partialBytes)
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.outputSplatURL),
            canonicalPly
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.paths.outputSplatReceiptURL),
            canonicalReceipt
        )
        XCTAssertEqual(activeTransactionURLs(in: fixture.paths), [transaction])
    }

    func testMoreThan256OrdinaryOutputEntriesDoNotBlockResolution() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("source.ply")
        let evidence = try writeSplat(at: source, x: 5)
        let published = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: makeReceipt(evidence: evidence),
            projectPaths: fixture.paths
        )
        for index in 0..<300 {
            let url = fixture.paths.outputURL.appendingPathComponent(
                String(format: "ordinary-%03d.bin", index)
            )
            XCTAssertTrue(FileManager.default.createFile(
                atPath: url.path,
                contents: Data([UInt8(index & 0xff)])
            ))
            XCTAssertEqual(Darwin.chmod(url.path, 0o600), 0)
        }
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(published)
        )
    }

    func testThreeHundredPublicationsLeaveNoRetiredDirectories() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("source.ply")
        let evidence = try writeSplat(at: source, x: 6)
        var latest: ValidatedPublishedResult?
        for index in 0..<300 {
            latest = try PublishedResultPairStore.publish(
                sourceURL: source,
                receipt: makeReceipt(
                    evidence: evidence,
                    publicationID: UUID(),
                    publishedAt: Date(timeIntervalSince1970: 1_767_225_600 + Double(index))
                ),
                projectPaths: fixture.paths
            )
        }
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(try XCTUnwrap(latest))
        )
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.outputURL.path
        )
        XCTAssertFalse(entries.contains {
            $0.hasPrefix(".published-result-tx-")
                || $0.hasPrefix(".published-result-retired-")
        })
    }

    func testSuppliedProjectRootDescriptorRejectsCopiedReplacementBeforeMutation() throws {
        let fixture = try makeProject()
        let parent = fixture.root.deletingLastPathComponent()
        let displaced = parent.appendingPathComponent(
            "descriptor-bound-original-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: displaced)
        }
        let descriptor = Darwin.open(
            fixture.root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }

        let replacementResult = LockedResult<Void>()
        var operations = PublishedResultPairOperations.system()
        operations.willOpenProjectRoot = {
            replacementResult.capture {
                try FileManager.default.moveItem(at: fixture.root, to: displaced)
                try FileManager.default.copyItem(at: displaced, to: fixture.root)
            }
        }

        XCTAssertThrowsError(try PublishedResultPairStore.resolve(
            projectPaths: fixture.paths,
            projectRootDescriptor: descriptor,
            operations: operations,
            shouldCancel: { false }
        )) { error in
            XCTAssertEqual(error as? PublishedResultPairError, .unsafeOutput)
        }
        XCTAssertNoThrow(try replacementResult.get())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.publishedResultLockURL.path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: displaced.appendingPathComponent(
                "Output/.published-result.lock"
            ).path
        ))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: fixture.paths.outputURL.path),
            []
        )
    }

    func testDescriptorBoundPublicationNeverWritesCopiedReplacementRoot() throws {
        let fixture = try makeProject()
        let parent = fixture.root.deletingLastPathComponent()
        let displaced = parent.appendingPathComponent(
            "descriptor-publication-original-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: displaced)
        }
        let source = fixture.root.appendingPathComponent("source.ply")
        let evidence = try writeSplat(at: source, x: 4)
        let descriptor = Darwin.open(
            fixture.root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }

        let replacementResult = LockedResult<Void>()
        var operations = PublishedResultPairOperations.system()
        operations.willOpenProjectRoot = {
            replacementResult.capture {
                try FileManager.default.moveItem(at: fixture.root, to: displaced)
                try FileManager.default.copyItem(at: displaced, to: fixture.root)
            }
        }

        XCTAssertThrowsError(try PublishedResultPairStore.publish(
            sourceProjectRelativePath: "source.ply",
            projectPaths: fixture.paths,
            projectRootDescriptor: descriptor,
            operations: operations,
            shouldCancel: { false }
        ) { _ in
            makeReceipt(evidence: evidence)
        }) { error in
            XCTAssertEqual(error as? PublishedResultPairError, .unsafeOutput)
        }
        XCTAssertNoThrow(try replacementResult.get())
        for root in [fixture.root, displaced] {
            let output = root.appendingPathComponent("Output", isDirectory: true)
            let names = try FileManager.default.contentsOfDirectory(atPath: output.path)
            XCTAssertFalse(names.contains("splat.ply"))
            XCTAssertFalse(names.contains("splat_receipt.json"))
            XCTAssertFalse(names.contains(".published-result.lock"))
            XCTAssertFalse(names.contains { $0.hasPrefix(".published-result-") })
        }
    }

    func testFullPublicationAuthorityIsDurableBeforeBuildDirectoryAppears() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("source.ply")
        let evidence = try writeSplat(at: source, x: 7)
        let observedNames = LockedValues<[String]>()
        var operations = PublishedResultPairOperations.system()
        operations.didReachCheckpoint = { checkpoint in
            guard checkpoint == .transactionBuildOwnershipDurable else { return }
            observedNames.append(
                (try? FileManager.default.contentsOfDirectory(
                    atPath: fixture.paths.outputURL.path
                )) ?? []
            )
        }

        _ = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: makeReceipt(evidence: evidence),
            projectPaths: fixture.paths,
            operations: operations
        )

        let names = try XCTUnwrap(observedNames.values.first)
        XCTAssertTrue(names.contains {
            $0.hasPrefix(".published-result-build-authority-")
        })
        XCTAssertFalse(names.contains {
            $0.hasPrefix(".published-result-build-")
                && !$0.hasPrefix(".published-result-build-authority-")
        })
    }

    func testViewerTimingAuthorityIsDurableBeforeBuildDirectoryOrPlaceholdersAppear() throws {
        let timing = try makeTimingFixture()
        defer { try? FileManager.default.removeItem(at: timing.root) }
        let observedNames = LockedValues<[String]>()
        var operations = PublishedResultPairOperations.system()
        operations.didReachCheckpoint = { checkpoint in
            guard checkpoint == .receiptTransactionBuildOwnershipDurable else { return }
            observedNames.append(
                (try? FileManager.default.contentsOfDirectory(
                    atPath: timing.paths.outputURL.path
                )) ?? []
            )
        }

        _ = try PublishedResultPairStore.recordFirstViewerReadyTiming(
            142.25,
            expectedPublicationID: timing.receipt.publicationID,
            projectPaths: timing.paths,
            operations: operations
        )

        let names = try XCTUnwrap(observedNames.values.first)
        XCTAssertTrue(names.contains {
            $0.hasPrefix(".published-receipt-build-authority-")
        })
        XCTAssertFalse(names.contains {
            $0.hasPrefix(".published-receipt-build-")
                && !$0.hasPrefix(".published-receipt-build-authority-")
        })
    }

    func testMarkerlessBuildDirectoriesRemainPreservedConflicts() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for prefix in [
            ".published-result-build-",
            ".published-receipt-build-",
        ] {
            let build = fixture.paths.outputURL.appendingPathComponent(
                prefix + UUID().uuidString.lowercased(),
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: build,
                withIntermediateDirectories: false
            )
            XCTAssertEqual(Darwin.chmod(build.path, 0o700), 0)
            let foreign = build.appendingPathComponent("foreign.bin")
            try Data("do-not-delete".utf8).write(to: foreign)
            XCTAssertEqual(Darwin.chmod(foreign.path, 0o600), 0)

            XCTAssertEqual(
                try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
                .conflict(.pendingTransaction)
            )
            XCTAssertEqual(try Data(contentsOf: foreign), Data("do-not-delete".utf8))
            try FileManager.default.removeItem(at: build)
        }
    }

    func testCaseInsensitiveReservedNamespaceAliasesFailClosedAndRemainUntouched() throws {
        let reservedPrefixes = [
            ".published-result-tx-",
            ".published-result-build-",
            ".published-result-build-authority-",
            ".published-result-retired-",
            ".published-receipt-build-",
            ".published-receipt-build-authority-",
            ".published-receipt-tx-",
            ".published-receipt-retired-",
            ".published-receipt-cleanup-",
        ]
        let prefixes = reservedPrefixes
            + reservedPrefixes.map { ".cleanup-" + $0 }
            + reservedPrefixes.map { ".cleanup-.cleanup-" + $0 }
        for prefix in prefixes {
            let fixture = try makeProject()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let alias = prefix.uppercased()
                + "11111111-1111-4111-8111-111111111111"
            let foreign = fixture.paths.outputURL.appendingPathComponent(alias)
            let bytes = Data("foreign-reserved-alias".utf8)
            try bytes.write(to: foreign)
            XCTAssertEqual(Darwin.chmod(foreign.path, 0o600), 0)
            var operations = PublishedResultPairOperations.system()
            operations.volumeCaseSensitivity = { _ in 0 }

            XCTAssertEqual(
                try PublishedResultPairStore.resolve(
                    projectPaths: fixture.paths,
                    operations: operations
                ),
                .conflict(.pendingTransaction),
                "Prefix: \(prefix)"
            )
            XCTAssertEqual(try Data(contentsOf: foreign), bytes, "Prefix: \(prefix)")
        }
    }

    func testCaseSensitiveVolumeDoesNotReserveCaseDistinctOrdinaryName() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let ordinary = fixture.paths.outputURL.appendingPathComponent(
            ".PUBLISHED-RESULT-TX-ordinary-note.txt"
        )
        let bytes = Data("ordinary-case-distinct-name".utf8)
        try bytes.write(to: ordinary)
        XCTAssertEqual(Darwin.chmod(ordinary.path, 0o600), 0)
        var operations = PublishedResultPairOperations.system()
        operations.volumeCaseSensitivity = { _ in 1 }

        XCTAssertEqual(
            try PublishedResultPairStore.resolve(
                projectPaths: fixture.paths,
                operations: operations
            ),
            .unavailable(.missingPair)
        )
        XCTAssertEqual(try Data(contentsOf: ordinary), bytes)
    }

    func testUnknownVolumeCaseSensitivityFailsBeforeLockCreation() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var operations = PublishedResultPairOperations.system()
        operations.volumeCaseSensitivity = { _ in
            Darwin.__error().pointee = EIO
            return -1
        }

        XCTAssertThrowsError(try PublishedResultPairStore.resolve(
            projectPaths: fixture.paths,
            operations: operations
        )) { error in
            XCTAssertEqual(error as? PublishedResultPairError, .unsafeOutput)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.publishedResultLockURL.path
        ))
    }

    func testFinalTransactionRemovalFsyncFailureReturnsCommittedPair() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("source.ply")
        let evidence = try writeSplat(at: source, x: 8)
        let receipt = makeReceipt(evidence: evidence)
        let system = PublishedResultPairOperations.system()
        let failNextDirectorySync = OneShotGate()
        var operations = system
        operations.didReachCheckpoint = { checkpoint in
            if checkpoint == .transactionDirectoryRemoved {
                failNextDirectorySync.arm()
            }
        }
        operations.synchronizeDirectory = { descriptor in
            if failNextDirectorySync.consume() {
                Darwin.__error().pointee = EIO
                return -1
            }
            return system.synchronizeDirectory(descriptor)
        }

        let committed = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: receipt,
            projectPaths: fixture.paths,
            operations: operations
        )

        XCTAssertEqual(committed.receipt, receipt)
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(committed)
        )
        XCTAssertFalse(try outputNames(in: fixture.paths).contains {
            $0.hasPrefix(".published-result-tx-")
                || $0.hasPrefix(".published-result-retired-")
                || $0.hasPrefix(".cleanup-.published-result-")
        })
    }

    func testValidatedFileReplacementBeforeRemovalIsPreserved() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("source.ply")
        let evidence = try writeSplat(at: source, x: 5)
        let foreignBytes = Data("foreign-after-file-validation".utf8)
        let mutation = LockedResult<Void>()
        let mutated = LockedFlag()
        var operations = PublishedResultPairOperations.system()
        operations.didValidateOwnedEntryForRemoval = { parent, name, isDirectory in
            guard !isDirectory, name.contains("journal-"), !mutated.value else { return }
            mutated.set()
            mutation.capture {
                let saved = name + ".saved"
                guard name.withCString({ sourceName in
                    saved.withCString { savedName in
                        Darwin.renameat(parent, sourceName, parent, savedName)
                    }
                }) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
                try writePairStoreTestFile(
                    parent: parent,
                    name: name,
                    data: foreignBytes,
                    mode: 0o600
                )
            }
        }

        XCTAssertThrowsError(try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: makeReceipt(evidence: evidence),
            projectPaths: fixture.paths,
            operations: operations
        ))
        XCTAssertNoThrow(try mutation.get())
        XCTAssertTrue(try outputTreeContains(bytes: foreignBytes, paths: fixture.paths))
    }

    func testValidatedDirectoryReplacementBeforeRemovalIsPreserved() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("source.ply")
        let evidence = try writeSplat(at: source, x: 6)
        let mutation = LockedResult<Void>()
        let replacementName = LockedValues<String>()
        var operations = PublishedResultPairOperations.system()
        operations.didValidateOwnedEntryForRemoval = { parent, name, isDirectory in
            guard isDirectory,
                  name.hasPrefix(".cleanup-.published-result-retired-") else { return }
            replacementName.append(name)
            mutation.capture {
                let saved = name + ".saved"
                guard name.withCString({ sourceName in
                    saved.withCString { savedName in
                        Darwin.renameat(parent, sourceName, parent, savedName)
                    }
                }) == 0,
                name.withCString({ Darwin.mkdirat(parent, $0, mode_t(0o700)) }) == 0 else {
                    throw POSIXError(.init(rawValue: errno) ?? .EIO)
                }
            }
        }

        XCTAssertThrowsError(try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: makeReceipt(evidence: evidence),
            projectPaths: fixture.paths,
            operations: operations
        ))
        XCTAssertNoThrow(try mutation.get())
        let name = try XCTUnwrap(replacementName.values.first)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.paths.outputURL.appendingPathComponent(name).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: fixture.paths.outputURL.appendingPathComponent(name + ".saved").path
        ))
    }

    func testLockContentionCancellationIsBoundedAndPreservesCanonicalPair() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let source = fixture.root.appendingPathComponent("source.ply")
        _ = try writeSplat(at: source, x: 7)
        let published = try publish(source: source, paths: fixture.paths)
        let holder = Darwin.open(
            fixture.paths.publishedResultLockURL.path,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(holder, 0)
        defer { Darwin.close(holder) }
        var heldLock = Darwin.flock()
        heldLock.l_start = 0
        heldLock.l_len = 0
        heldLock.l_pid = 0
        heldLock.l_type = Int16(F_WRLCK)
        heldLock.l_whence = Int16(SEEK_SET)
        XCTAssertEqual(withUnsafeMutablePointer(to: &heldLock) {
            Darwin.fcntl(holder, F_OFD_SETLK, $0)
        }, 0)
        defer {
            heldLock.l_type = Int16(F_UNLCK)
            _ = withUnsafeMutablePointer(to: &heldLock) {
                Darwin.fcntl(holder, F_OFD_SETLK, $0)
            }
        }

        let waiting = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        let cancellation = LockedFlag()
        let result = LockedResult<PublishedResultAvailability>()
        var operations = PublishedResultPairOperations.system()
        operations.didReachCheckpoint = { checkpoint in
            if checkpoint == .lockWaitStarted { waiting.signal() }
        }
        let cancellationOperations = operations
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            result.capture {
                try PublishedResultPairStore.resolve(
                    projectPaths: fixture.paths,
                    operations: cancellationOperations,
                    shouldCancel: { cancellation.value }
                )
            }
            done.signal()
        }
        XCTAssertEqual(waiting.wait(timeout: .now() + 2), .success)
        cancellation.set()
        XCTAssertEqual(done.wait(timeout: .now() + 1), .success)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.25)
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertTrue(error is CancellationError)
        }

        heldLock.l_type = Int16(F_UNLCK)
        XCTAssertEqual(withUnsafeMutablePointer(to: &heldLock) {
            Darwin.fcntl(holder, F_OFD_SETLK, $0)
        }, 0)
        XCTAssertEqual(
            try PublishedResultPairStore.resolve(projectPaths: fixture.paths),
            .available(published)
        )
    }
}

private extension PublishedResultPairStoreTests {
    struct CrashFixture {
        let root: URL
        let paths: ProjectPaths
        let previous: ValidatedPublishedResult?
        let next: ValidatedPublishedResult?
    }

    struct TimingFixture {
        let root: URL
        let paths: ProjectPaths
        let receipt: PublishedSplatReceipt
        let published: ValidatedPublishedResult
    }

    struct RetiredTimingFixture {
        let root: URL
        let paths: ProjectPaths
        let published: ValidatedPublishedResult
        let committed: ValidatedPublishedResult
        let retired: URL
        let authority: URL
    }

    func makeProject() throws -> (root: URL, paths: ProjectPaths) {
        let root = try TestFileBuilder.makeTempDir()
            .appendingPathComponent("Published Pair.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        return (root, paths)
    }

    func publish(source: URL, paths: ProjectPaths) throws -> ValidatedPublishedResult {
        let evidence = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        return try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: makeReceipt(evidence: evidence),
            projectPaths: paths
        )
    }

    func makeTimingFixture() throws -> TimingFixture {
        let fixture = try makeProject()
        let source = fixture.root.appendingPathComponent("viewer-ready-source.ply")
        let evidence = try writeSplat(at: source, x: 6)
        let receipt = makeReceipt(
            evidence: evidence,
            createToViewerReadySeconds: nil
        )
        let published = try PublishedResultPairStore.publish(
            sourceURL: source,
            receipt: receipt,
            projectPaths: fixture.paths
        )
        return TimingFixture(
            root: fixture.root,
            paths: fixture.paths,
            receipt: receipt,
            published: published
        )
    }

    func makeRetiredTimingFixture() throws -> RetiredTimingFixture {
        let timing = try makeTimingFixture()
        var operations = PublishedResultPairOperations.system()
        operations.willUnlinkQuarantinedEntry = { name in
            guard name == "cleanup-authorized.json" else { return }
            throw NSError(
                domain: "PublishedResultPairStoreTests.retired-timing-fixture",
                code: 1
            )
        }
        let committed = try PublishedResultPairStore.recordFirstViewerReadyTiming(
            142.25,
            expectedPublicationID: timing.receipt.publicationID,
            projectPaths: timing.paths,
            operations: operations
        )
        let entries = try FileManager.default.contentsOfDirectory(
            at: timing.paths.outputURL,
            includingPropertiesForKeys: nil
        )
        return RetiredTimingFixture(
            root: timing.root,
            paths: timing.paths,
            published: timing.published,
            committed: committed,
            retired: try XCTUnwrap(entries.first {
                $0.lastPathComponent.hasPrefix(".published-receipt-retired-")
            }),
            authority: try XCTUnwrap(entries.first {
                $0.lastPathComponent.hasPrefix(".published-receipt-cleanup-")
            })
        )
    }

    func makeCrashFixture(
        phase target: PublishedResultPairJournalPhase,
        hasPrevious: Bool
    ) throws -> CrashFixture {
        let fixture = try makeProject()
        let oldSource = fixture.root.appendingPathComponent("old-source.ply")
        let newSource = fixture.root.appendingPathComponent("new-source.ply")
        let oldEvidence = try writeSplat(at: oldSource, x: 7)
        let newEvidence = try writeSplat(at: newSource, x: 8)
        let oldReceipt = makeReceipt(
            evidence: oldEvidence,
            publicationID: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        )
        let newReceipt = makeReceipt(
            evidence: newEvidence,
            publicationID: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        )
        let previous = hasPrevious ? try PublishedResultPairStore.publish(
            sourceURL: oldSource,
            receipt: oldReceipt,
            projectPaths: fixture.paths
        ) : nil
        let transactionID = UUID(uuidString: "cccccccc-cccc-4ccc-8ccc-cccccccccccc")!
        _ = try PublishedResultPairStore.testCreateTransactionFixture(
            projectPaths: fixture.paths,
            transactionID: transactionID,
            publicationID: newReceipt.publicationID,
            previousPublicationID: previous?.receipt.publicationID
        )
        if target == .created {
            return CrashFixture(
                root: fixture.root,
                paths: fixture.paths,
                previous: previous,
                next: nil
            )
        }

        try PublishedResultPairStore.testOverwriteTransactionFixtureFile(
            named: "new.ply",
            data: Data(contentsOf: newSource),
            projectPaths: fixture.paths,
            transactionID: transactionID
        )
        try PublishedResultPairStore.testRecordTransactionFixturePhase(
            .newPlyDurable,
            projectPaths: fixture.paths,
            transactionID: transactionID
        )
        if target == .newPlyDurable {
            return CrashFixture(
                root: fixture.root,
                paths: fixture.paths,
                previous: previous,
                next: nil
            )
        }

        try PublishedResultPairStore.testOverwriteTransactionFixtureFile(
            named: "new-receipt.json",
            data: PublishedSplatReceiptStore.encode(newReceipt),
            projectPaths: fixture.paths,
            transactionID: transactionID
        )
        try PublishedResultPairStore.testRecordTransactionFixturePhase(
            .newReceiptDurable,
            projectPaths: fixture.paths,
            transactionID: transactionID
        )
        if target == .newReceiptDurable {
            return CrashFixture(
                root: fixture.root,
                paths: fixture.paths,
                previous: previous,
                next: nil
            )
        }
        try PublishedResultPairStore.testRecordTransactionFixturePhase(
            .prepared,
            projectPaths: fixture.paths,
            transactionID: transactionID
        )
        if target == .prepared {
            return CrashFixture(
                root: fixture.root,
                paths: fixture.paths,
                previous: previous,
                next: nil
            )
        }

        if hasPrevious {
            try PublishedResultPairStore.testRecordTransactionFixturePhase(
                .previousPlyMoved,
                projectPaths: fixture.paths,
                transactionID: transactionID
            )
            if target == .previousPlyMoved {
                return CrashFixture(
                    root: fixture.root,
                    paths: fixture.paths,
                    previous: previous,
                    next: nil
                )
            }
            try PublishedResultPairStore.testRecordTransactionFixturePhase(
                .previousPairMoved,
                projectPaths: fixture.paths,
                transactionID: transactionID
            )
            if target == .previousPairMoved {
                return CrashFixture(
                    root: fixture.root,
                    paths: fixture.paths,
                    previous: previous,
                    next: nil
                )
            }
        }

        try PublishedResultPairStore.testRecordTransactionFixturePhase(
            .newPlyInstalled,
            projectPaths: fixture.paths,
            transactionID: transactionID
        )
        if target == .newPlyInstalled {
            return CrashFixture(
                root: fixture.root,
                paths: fixture.paths,
                previous: previous,
                next: nil
            )
        }

        try PublishedResultPairStore.testRecordTransactionFixturePhase(
            .receiptCommitted,
            projectPaths: fixture.paths,
            transactionID: transactionID
        )
        let next = ValidatedPublishedResult(
            receipt: newReceipt,
            outputURL: fixture.paths.outputSplatURL,
            outputEvidence: newEvidence
        )
        if target == .receiptCommitted {
            return CrashFixture(
                root: fixture.root,
                paths: fixture.paths,
                previous: previous,
                next: next
            )
        }
        try PublishedResultPairStore.testRecordTransactionFixturePhase(
            .validated,
            projectPaths: fixture.paths,
            transactionID: transactionID
        )
        return CrashFixture(
            root: fixture.root,
            paths: fixture.paths,
            previous: previous,
            next: next
        )
    }

    func activeTransactionURLs(in paths: ProjectPaths) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: paths.outputURL,
            includingPropertiesForKeys: nil
        )) ?? []
        return entries.filter {
            $0.lastPathComponent.hasPrefix(".published-result-tx-")
        }
    }

    func outputNames(in paths: ProjectPaths) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: paths.outputURL.path)
    }

    func transactionPayloadBytes(in paths: ProjectPaths) throws -> UInt64 {
        let directories = try FileManager.default.contentsOfDirectory(
            at: paths.outputURL,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(".published-result-tx-")
                || $0.lastPathComponent.hasPrefix(".published-result-retired-")
        }
        let names = ["new.ply", "new-receipt.json", "old.ply", "old-receipt.json"]
        return try directories.reduce(into: UInt64(0)) { total, directory in
            for name in names {
                let file = directory.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                total += (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            }
        }
    }

    func writeSplat(at url: URL, x: Float) throws -> ValidatedPlyArtifactEvidence {
        let text = """
        ply
        format ascii 1.0
        element vertex 1
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
        \(Int(x)) 0 0 1 1 1 -4 -4 -4 1 1 0 0 0
        """
        try text.write(to: url, atomically: false, encoding: .utf8)
        XCTAssertEqual(Darwin.chmod(url.path, 0o600), 0)
        return try ProjectArtifactValidator.validatedPlyEvidence(at: url)
    }

    func mutateFirstFloatSameSize(at url: URL) throws {
        try mutatePublishedPairTestPly(at: url)
    }

    func makeReceipt(
        evidence: ValidatedPlyArtifactEvidence,
        publicationID: UUID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
        publishedAt: Date = Date(timeIntervalSince1970: 1_767_225_600),
        createToViewerReadySeconds: Double? = 117.75
    ) -> PublishedSplatReceipt {
        let plan = makePlan()
        return PublishedSplatReceipt(
            publicationID: publicationID,
            projectID: UUID(uuidString: "99999999-8888-4777-8666-555555555555")!,
            publishedAt: publishedAt,
            outputEvidence: evidence,
            lineage: PublishedSplatLineage(
                trainingManifestSHA256: String(repeating: "b", count: 64),
                trainingInputDigest: String(repeating: "c", count: 64),
                trainingGeometryDigest: String(repeating: "d", count: 64)
            ),
            presentation: PublishedResultPresentation(
                requestedRunOptions: RequestedRunOptions(
                    capturePath: .orbit,
                    detailProfile: .balanced,
                    cameraGrouping: .sameCameraAndLens,
                    lensProjection: .perspective,
                    inputOrdering: .automatic,
                    resourcePolicy: .maximumPerformance,
                    photoSelection: .useAllValidPhotos
                ),
                resolvedRunPlan: plan,
                reconstruction: PublishedReconstructionSummary(
                    registeredViewCount: 18,
                    totalViewCount: 20,
                    pointCount: 45_678,
                    observationCount: 123_456,
                    medianPixelResidual: 0.42,
                    p90PixelResidual: 1.25,
                    solverVersion: "COLMAP 3.12",
                    modelVersion: "classic-incremental",
                    cameraModel: "SIMPLE_RADIAL",
                    residualProvenance: "colmap-text-tracks-v1",
                    usedPartialCoverageAcceptance: true,
                    secondLargestModelRegisteredViewCount: 2
                ),
                orientation: PublishedOrientationSummary(
                    status: .verified,
                    openingDirection: CanonicalDirection(x: 0, y: 0, z: -1),
                    allowsViewOnlyUprightFlip: false
                ),
                stageTimings: [
                    StageTimingRecord(
                        stage: .trainSplat,
                        startedAt: Date(timeIntervalSince1970: 1_767_225_100),
                        durationSeconds: 95.5
                    ),
                ],
                autoTunerSnapshot: PublishedAutoTunerSnapshot(resolvedRunPlan: plan),
                trainerVersion: "msplat-test",
                runtimeVersion: "runtime-test",
                completedIteration: 12_345,
                trainingDurationSeconds: 12.5,
                createToViewerReadySeconds: createToViewerReadySeconds
            )
        )
    }

    func makePlan() -> ResolvedRunPlan {
        RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(
                capturePath: .orbit,
                detailProfile: .balanced,
                cameraGrouping: .sameCameraAndLens,
                lensProjection: .perspective,
                inputOrdering: .automatic,
                resourcePolicy: .maximumPerformance,
                photoSelection: .useAllValidPhotos
            ),
            input: .photos(folder: "Inputs/photos"),
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: .none
        )
    }

    func DarwinMode(at url: URL) -> mode_t? {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else { return nil }
        return status.st_mode & 0o7777
    }
}

private func publishedPairTestTransactions(in paths: ProjectPaths) -> [URL] {
    let entries = (try? FileManager.default.contentsOfDirectory(
        at: paths.outputURL,
        includingPropertiesForKeys: nil
    )) ?? []
    return entries.filter {
        $0.lastPathComponent.hasPrefix(".published-result-tx-")
    }
}

private func writePairStoreTestFile(
    parent: Int32,
    name: String,
    data: Data,
    mode: mode_t
) throws {
    let descriptor = name.withCString {
        Darwin.openat(
            parent,
            $0,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode
        )
    }
    guard descriptor >= 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    defer { Darwin.close(descriptor) }
    guard Darwin.fchmod(descriptor, mode) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    var offset = 0
    try data.withUnsafeBytes { bytes in
        while offset < bytes.count {
            let written = Darwin.write(
                descriptor,
                bytes.baseAddress?.advanced(by: offset),
                bytes.count - offset
            )
            if written < 0, errno == EINTR { continue }
            guard written > 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            offset += written
        }
    }
    guard Darwin.fsync(descriptor) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
}

private func outputTreeContains(bytes: Data, paths: ProjectPaths) throws -> Bool {
    guard let enumerator = FileManager.default.enumerator(
        at: paths.outputURL,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: []
    ) else {
        return false
    }
    while let entry = enumerator.nextObject() as? URL {
        let values = try entry.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else { continue }
        if try Data(contentsOf: entry) == bytes { return true }
    }
    return false
}

private func mutatePublishedPairTestPly(at url: URL) throws {
    let data = try Data(contentsOf: url)
    guard let marker = data.range(of: Data("end_header\n".utf8)) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let descriptor = Darwin.open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    defer { Darwin.close(descriptor) }
    var byte = data[marker.upperBound] ^ 0x01
    guard Darwin.pwrite(descriptor, &byte, 1, off_t(marker.upperBound)) == 1,
          Darwin.fsync(descriptor) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
}

private func mutatePublishedPairTestPlyRestoringTimes(at url: URL) throws {
    let data = try Data(contentsOf: url)
    guard let marker = data.range(of: Data("end_header\n".utf8)) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let descriptor = Darwin.open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    defer { Darwin.close(descriptor) }
    var original = stat()
    guard Darwin.fstat(descriptor, &original) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    var byte = data[marker.upperBound] ^ 0x01
    guard Darwin.pwrite(descriptor, &byte, 1, off_t(marker.upperBound)) == 1,
          Darwin.fsync(descriptor) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    var originalTimes = [original.st_atimespec, original.st_mtimespec]
    guard Darwin.futimens(descriptor, &originalTimes) == 0,
          Darwin.fsync(descriptor) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
}

private func replaceEqualLengthBytesRestoringTimes(
    at url: URL,
    replacing oldBytes: Data,
    with newBytes: Data
) throws {
    guard oldBytes.count == newBytes.count else {
        throw CocoaError(.fileWriteInvalidFileName)
    }
    let data = try Data(contentsOf: url)
    guard let range = data.range(of: oldBytes) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let descriptor = Darwin.open(url.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    defer { Darwin.close(descriptor) }
    var original = stat()
    guard Darwin.fstat(descriptor, &original) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    let written = newBytes.withUnsafeBytes { bytes in
        Darwin.pwrite(
            descriptor,
            bytes.baseAddress,
            bytes.count,
            off_t(range.lowerBound)
        )
    }
    guard written == newBytes.count, Darwin.fsync(descriptor) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    var originalTimes = [original.st_atimespec, original.st_mtimespec]
    guard Darwin.futimens(descriptor, &originalTimes) == 0,
          Darwin.fsync(descriptor) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
}

private func journalFileIdentityObject(at url: URL) throws -> [String: Any] {
    var status = stat()
    guard Darwin.lstat(url.path, &status) == 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }
    return [
        "device": UInt64(status.st_dev),
        "inode": UInt64(status.st_ino),
        "byteCount": Int64(status.st_size),
        "owner": status.st_uid,
        "mode": status.st_mode,
        "linkCount": UInt64(status.st_nlink),
        "modifiedSeconds": Int64(status.st_mtimespec.tv_sec),
        "modifiedNanoseconds": Int64(status.st_mtimespec.tv_nsec),
        "changedSeconds": Int64(status.st_ctimespec.tv_sec),
        "changedNanoseconds": Int64(status.st_ctimespec.tv_nsec),
    ]
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false
    var value: Bool { lock.withLock { storage } }
    func set() { lock.withLock { storage = true } }
}

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    var values: [Value] { lock.withLock { storage } }
    func append(_ value: Value) { lock.withLock { storage.append(value) } }
}

private final class OneShotGate: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false
    func arm() { lock.withLock { armed = true } }
    func consume() -> Bool {
        lock.withLock {
            guard armed else { return false }
            armed = false
            return true
        }
    }
}

private final class OneShotCallFailure: @unchecked Sendable {
    private let lock = NSLock()
    private let targetCall: Int
    private var calls = 0
    private var reached = false

    init(targetCall: Int) {
        self.targetCall = targetCall
    }

    func shouldFail() -> Bool {
        lock.withLock {
            calls += 1
            return calls == targetCall
        }
    }

    func markReached() {
        lock.withLock { reached = true }
    }

    func consumeReached() -> Bool {
        lock.withLock {
            guard reached else { return false }
            reached = false
            return true
        }
    }
}

private final class CleanupAuthorizationWriteFault: @unchecked Sendable {
    private enum State {
        case idle
        case armed
        case blocked
    }

    private let lock = NSLock()
    private var state = State.idle

    func arm() {
        lock.withLock {
            if state == .idle { state = .armed }
        }
    }

    func write(
        descriptor: Int32,
        bytes: UnsafeRawPointer?,
        count: Int,
        system: @Sendable (Int32, UnsafeRawPointer?, Int) -> Int
    ) -> Int {
        let action: State = lock.withLock {
            let current = state
            switch state {
            case .armed:
                state = .blocked
            case .idle, .blocked:
                break
            }
            return current
        }
        switch action {
        case .armed:
            return system(descriptor, bytes, min(count, 8))
        case .blocked:
            Darwin.__error().pointee = ENOSPC
            return -1
        case .idle:
            return system(descriptor, bytes, count)
        }
    }
}

private final class LockedResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Result<Value, Error>?

    func capture(_ operation: () throws -> Value) {
        let result = Result(catching: operation)
        lock.withLock { storage = result }
    }

    func get() throws -> Value {
        try lock.withLock {
            guard let storage else { throw CocoaError(.coderInvalidValue) }
            return try storage.get()
        }
    }
}

private final class LockedURL: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: URL?
    var value: URL? { lock.withLock { storage } }
    func set(_ value: URL) { lock.withLock { storage = value } }
}
