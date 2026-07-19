#if canImport(XCTest)
import Darwin
import CryptoKit
import Foundation
import XCTest
@testable import EasySplatCore

final class ProjectPublicationTransactionTests: XCTestCase {
    func testProjectPublicationCrashHelperEntryPoint() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment["EASYSPLAT_PUBLICATION_HELPER_MODE"] else { return }
        let base = URL(
            fileURLWithPath: try XCTUnwrap(environment["EASYSPLAT_PUBLICATION_HELPER_BASE"]),
            isDirectory: true
        )
        if mode == "reconcile" {
            _ = ProjectPublicationTransaction.reconcile(in: base)
            let marker = URL(fileURLWithPath: try XCTUnwrap(
                environment["EASYSPLAT_PUBLICATION_HELPER_MARKER"]
            ))
            try Data("reconciled".utf8).write(to: marker, options: .atomic)
            return
        }

        let checkpoint = try XCTUnwrap(ProjectPublicationTransaction.Checkpoint(
            rawValue: try XCTUnwrap(environment["EASYSPLAT_PUBLICATION_HELPER_CHECKPOINT"])
        ))
        let id = environment["EASYSPLAT_PUBLICATION_HELPER_PROJECT_ID"]
            .flatMap(UUID.init(uuidString:)) ?? UUID()
        let title = "Child Crash \(checkpoint.rawValue)"
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: title,
            projectID: id,
            checkpointHandler: { reached in
                if reached == checkpoint { Darwin._exit(86) }
            }
        )
        let prepared = try Self.prepareMixedInputs(
            in: transaction.bundleURL,
            id: id,
            title: title,
            checkpoint: { try transaction.reached($0) }
        )
        switch mode {
        case "publish":
            try transaction.validateAndSeal(expectedMetadata: prepared)
            _ = try transaction.publish()
        case "abort-sealed":
            try transaction.validateAndSeal(expectedMetadata: prepared)
            try transaction.abort()
        case "abort-unsealed":
            try FileManager.default.removeItem(
                at: ProjectPaths(root: transaction.bundleURL).metadataURL
            )
            try transaction.abort()
        default:
            XCTFail("Unknown publication helper mode: \(mode)")
        }
    }

    func testChildExitCrashMatrixRecoversWithoutPartialOrReplacedProjects() throws {
        let prePublishCheckpoints: Set<ProjectPublicationTransaction.Checkpoint> = [
            .transactionRecordDurable,
            .bundleDirectoryCreated,
            .bundleRecordTemporaryDurable,
            .stagedRootCreated,
            .videoAdoptionRecordTemporaryDurable,
            .videoAdopted,
            .photoAdoptionRecordTemporaryDurable,
            .photosAdopted,
            .metadataValidationRecordTemporaryDurable,
            .initialMetadataValidated,
            .inputContentHashed,
            .metadataDurable,
            .readyReceiptDurable,
        ]
        let recoverableCompleteCheckpoints: Set<ProjectPublicationTransaction.Checkpoint> = [
            .metadataValidationRecordTemporaryDurable,
            .initialMetadataValidated,
            .inputContentHashed,
            .metadataDurable,
            .readyReceiptDurable,
        ]

        for checkpoint in ProjectPublicationTransaction.Checkpoint.allCases {
            let base = temporaryDirectory(suffix: "publish-\(checkpoint.rawValue)")
            defer { try? FileManager.default.removeItem(at: base) }
            let existing = try makeExistingVisibleSentinel(in: base)
            let existingBundleIdentity = try identity(at: existing.bundle)
            let existingSentinelIdentity = try identity(at: existing.sentinel)
            let existingBundlePermissions = try permissions(at: existing.bundle)
            let projectID = UUID()
            let crash = try runCrashHelper(
                mode: "publish",
                base: base,
                checkpoint: checkpoint,
                projectID: projectID
            )
            XCTAssertEqual(crash.terminationReason, .exit, checkpoint.rawValue)
            XCTAssertEqual(crash.terminationStatus, 86, checkpoint.rawValue)

            let visibleBeforeRecovery = try visibleProjects(in: base).filter {
                $0.lastPathComponent != existing.bundle.lastPathComponent
            }
            XCTAssertEqual(
                visibleBeforeRecovery.count,
                prePublishCheckpoints.contains(checkpoint) ? 0 : 1,
                "partial visibility at \(checkpoint.rawValue)"
            )
            let unknown = try addUnknownTransactionRootEntry(
                in: base,
                suffix: checkpoint.rawValue
            )
            let unknownIdentity = try identity(at: unknown)
            let unknownPermissions = try permissions(at: unknown)
            let marker = base.appendingPathComponent("reconcile-marker")
            let reconcile = try runReconcileHelper(base: base, marker: marker)
            XCTAssertEqual(reconcile.terminationReason, .exit, checkpoint.rawValue)
            XCTAssertEqual(reconcile.terminationStatus, 0, checkpoint.rawValue)
            XCTAssertEqual(try Data(contentsOf: marker), Data("reconciled".utf8))
            XCTAssertEqual(try Data(contentsOf: existing.sentinel), Data("existing".utf8))
            XCTAssertEqual(try Data(contentsOf: unknown), Data("unknown".utf8))
            XCTAssertEqual(try identity(at: existing.bundle), existingBundleIdentity)
            XCTAssertEqual(try identity(at: existing.sentinel), existingSentinelIdentity)
            XCTAssertEqual(try permissions(at: existing.bundle), existingBundlePermissions)
            XCTAssertEqual(try identity(at: unknown), unknownIdentity)
            XCTAssertEqual(try permissions(at: unknown), unknownPermissions)
            XCTAssertEqual(
                try transactionContainerLeaves(in: base).sorted(),
                ["publication.lock", unknown.lastPathComponent].sorted(),
                checkpoint.rawValue
            )

            let expectedPublished = recoverableCompleteCheckpoints.contains(checkpoint)
                || !prePublishCheckpoints.contains(checkpoint)
            let newVisible = try visibleProjects(in: base).filter {
                $0.lastPathComponent != existing.bundle.lastPathComponent
            }
            XCTAssertEqual(newVisible.count, expectedPublished ? 1 : 0, checkpoint.rawValue)
            if let published = newVisible.first {
                XCTAssertEqual(
                    try ProjectMetadataStore.load(
                        from: ProjectPaths(root: published).metadataURL
                    ).id,
                    projectID,
                    checkpoint.rawValue
                )
            }
        }
    }

    func testChildExitDuringAbortCleanupNeverPublishesSealedOrUnsealedBundle() throws {
        let cleanupCheckpoints: [ProjectPublicationTransaction.Checkpoint] = [
            .cleanupIntentDurable,
            .envelopeQuarantined,
            .outerCleanupDurable,
            .bundleCleanupDurable,
            .cleanupProofRemoved,
            .cleanupComplete,
        ]
        for mode in ["abort-unsealed", "abort-sealed"] {
            for checkpoint in cleanupCheckpoints {
                let base = temporaryDirectory(suffix: "\(mode)-\(checkpoint.rawValue)")
                defer { try? FileManager.default.removeItem(at: base) }
                let existing = try makeExistingVisibleSentinel(in: base)
                let existingIdentity = try identity(at: existing.bundle)
                let crash = try runCrashHelper(
                    mode: mode,
                    base: base,
                    checkpoint: checkpoint
                )
                XCTAssertEqual(crash.terminationReason, .exit, "\(mode) \(checkpoint.rawValue)")
                XCTAssertEqual(crash.terminationStatus, 86, "\(mode) \(checkpoint.rawValue)")
                XCTAssertTrue(
                    try visibleProjects(in: base).filter {
                        $0.lastPathComponent != existing.bundle.lastPathComponent
                    }.isEmpty,
                    "abort exposed a project at \(mode) \(checkpoint.rawValue)"
                )
                let unknown = try addUnknownTransactionRootEntry(
                    in: base,
                    suffix: "\(mode)-\(checkpoint.rawValue)"
                )
                let unknownIdentity = try identity(at: unknown)
                let marker = base.appendingPathComponent("reconcile-marker")
                let reconcile = try runReconcileHelper(base: base, marker: marker)
                XCTAssertEqual(reconcile.terminationStatus, 0)
                XCTAssertTrue(try visibleProjects(in: base).filter {
                    $0.lastPathComponent != existing.bundle.lastPathComponent
                }.isEmpty)
                XCTAssertEqual(try Data(contentsOf: existing.sentinel), Data("existing".utf8))
                XCTAssertEqual(try Data(contentsOf: unknown), Data("unknown".utf8))
                XCTAssertEqual(try identity(at: existing.bundle), existingIdentity)
                XCTAssertEqual(try identity(at: unknown), unknownIdentity)
                XCTAssertEqual(
                    try transactionContainerLeaves(in: base).sorted(),
                    ["publication.lock", unknown.lastPathComponent].sorted()
                )
            }
        }
    }

    func testBeginCreatesOnlyOwnerPrivateHiddenTransaction() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }

        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: "Client Exterior",
            projectID: UUID()
        )

        let container = base.appendingPathComponent(
            ProjectPublicationTransaction.containerName,
            isDirectory: true
        )
        XCTAssertEqual(try permissions(at: container), 0o700)
        XCTAssertEqual(try permissions(at: transaction.envelopeURL), 0o700)
        XCTAssertEqual(try permissions(at: transaction.bundleURL), 0o700)
        XCTAssertTrue(transaction.envelopeURL.path.contains("/\(ProjectPublicationTransaction.containerName)/"))
        XCTAssertTrue(try visibleProjects(in: base).isEmpty)

        try transaction.abort()
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: container.path),
            ["publication.lock"]
        )
    }

    func testSealAndExclusivePublishPreserveTitleNotesAndPrivatePermissions() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID()
        let title = "4 Oak Street / Exterior"
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: title,
            projectID: id
        )
        let metadata = try Self.makeInitialProject(
            in: transaction.bundleURL,
            id: id,
            title: title,
            notes: "Wind from the west."
        )

        try transaction.validateAndSeal(expectedMetadata: metadata)
        let published = try transaction.publish()

        XCTAssertEqual(published, ProjectPublicationTransaction.candidateURL(
            in: transaction.baseURL,
            title: title,
            attempt: 0
        ))
        let loaded = try ProjectMetadataStore.load(from: ProjectPaths(root: published).metadataURL)
        XCTAssertEqual(loaded.id, id)
        XCTAssertEqual(loaded.title, title)
        XCTAssertEqual(loaded.notes, "Wind from the west.")
        XCTAssertEqual(try permissions(at: published), 0o700)
        XCTAssertEqual(try permissions(at: ProjectPaths(root: published).metadataURL), 0o600)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: base.appendingPathComponent(
                    ProjectPublicationTransaction.containerName,
                    isDirectory: true
                ).path
            ),
            ["publication.lock"]
        )
    }

    func testSealBindsCompleteExpectedMetadataSemantics() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: "Semantic Binding",
            projectID: id
        )
        defer { try? transaction.abort() }
        let expected = try Self.makeInitialProject(
            in: transaction.bundleURL,
            id: id,
            title: "Semantic Binding"
        )
        var changed = expected
        let receipt = try XCTUnwrap(changed.videoInputReceipts?.first)
        changed.videoInputReceipts = [VideoInputReceipt(
            schemaVersion: receipt.schemaVersion,
            projectRelativePath: receipt.projectRelativePath,
            safeDisplayName: "Substituted.mov",
            byteCount: receipt.byteCount,
            sha256: receipt.sha256,
            trackID: receipt.trackID,
            pixelWidth: receipt.pixelWidth,
            pixelHeight: receipt.pixelHeight,
            durationSeconds: receipt.durationSeconds,
            nominalFrameRate: receipt.nominalFrameRate,
            isHDR: receipt.isHDR,
            decodedFrameCount: receipt.decodedFrameCount,
            transformA: receipt.transformA,
            transformB: receipt.transformB,
            transformC: receipt.transformC,
            transformD: receipt.transformD,
            transformTX: receipt.transformTX,
            transformTY: receipt.transformTY,
            clipGroupID: receipt.clipGroupID,
            analysisPolicySHA256: receipt.analysisPolicySHA256,
            analysisArtifactPath: receipt.analysisArtifactPath,
            analysisArtifactByteCount: receipt.analysisArtifactByteCount,
            analysisArtifactSHA256: receipt.analysisArtifactSHA256
        )]
        changed.requestedRunOptions.detailProfile = .fast
        changed.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: changed.requestedRunOptions,
            input: changed.input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        try ProjectMetadataStore.save(
            changed,
            to: ProjectPaths(root: transaction.bundleURL).metadataURL
        )

        XCTAssertThrowsError(try transaction.validateAndSeal(expectedMetadata: expected)) {
            XCTAssertEqual($0 as? ProjectPublicationError, .invalidInitialMetadata)
        }
    }

    func testSealHashesAdoptedInputOnceAfterMetadataValidation() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let hashCount = LockedInt()
        let id = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: "One Content Pass",
            projectID: id,
            checkpointHandler: { checkpoint in
                if checkpoint == .inputContentHashed { hashCount.increment() }
            }
        )
        let metadata = try Self.makeInitialProject(
            in: transaction.bundleURL,
            id: id,
            title: "One Content Pass"
        )

        try transaction.validateAndSeal(expectedMetadata: metadata)

        XCTAssertEqual(hashCount.value, 1)
        try transaction.abort()
    }

    func testRepeatedDescriptorEnumerationReturnsTheSameExactSet() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: directory.appendingPathComponent("a"))
        try Data("b".utf8).write(to: directory.appendingPathComponent("b"))

        let (first, second) = try ProjectPublicationTransaction
            .repeatedDirectoryListingForTesting(at: directory.resolvingSymlinksInPath())

        XCTAssertEqual(first, ["a", "b"])
        XCTAssertEqual(second, first)
    }

    func testPublishEmitsEveryCheckpointOnceInOrder() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let checkpoints = LockedCheckpointList()
        let id = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: "Checkpoint Order",
            projectID: id,
            checkpointHandler: { checkpoints.append($0) }
        )
        let metadata = try Self.makeInitialProject(
            in: transaction.bundleURL,
            id: id,
            title: "Checkpoint Order"
        )
        try transaction.reached(.videoAdopted)
        try transaction.reached(.photosAdopted)
        try transaction.validateAndSeal(expectedMetadata: metadata)
        _ = try transaction.publish()

        XCTAssertEqual(checkpoints.value, [
            .transactionRecordDurable,
            .bundleRecordTemporaryDurable,
            .bundleDirectoryCreated,
            .stagedRootCreated,
            .videoAdoptionRecordTemporaryDurable,
            .videoAdopted,
            .photoAdoptionRecordTemporaryDurable,
            .photosAdopted,
            .metadataValidationRecordTemporaryDurable,
            .initialMetadataValidated,
            .inputContentHashed,
            .metadataDurable,
            .readyReceiptDurable,
            .renameComplete,
            .librarySynced,
            .cleanupIntentDurable,
            .envelopeQuarantined,
            .outerCleanupDurable,
            .bundleCleanupDurable,
            .cleanupProofRemoved,
            .cleanupComplete,
        ])
    }

    func testMutationAfterMetadataValidationCannotEscapeReceiptHashing() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let inputBox = LockedURLBox()
        let id = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: "Mutation Race",
            projectID: id,
            checkpointHandler: { checkpoint in
                guard checkpoint == .initialMetadataValidated,
                      let input = inputBox.value else { return }
                let handle = try FileHandle(forWritingTo: input)
                defer { try? handle.close() }
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: Data("video-mutated".utf8))
                try handle.synchronize()
            }
        )
        defer { try? transaction.abort() }
        let metadata = try Self.makeInitialProject(
            in: transaction.bundleURL,
            id: id,
            title: "Mutation Race",
            videoBytes: Data("video-fixture".utf8)
        )
        let input = transaction.bundleURL.appendingPathComponent("Originals/video-0000.mov")
        let before = try identity(at: input)
        inputBox.value = input

        XCTAssertThrowsError(try transaction.validateAndSeal(expectedMetadata: metadata)) {
            XCTAssertEqual($0 as? ProjectPublicationError, .pendingBundleChanged)
        }
        XCTAssertEqual(try identity(at: input), before, "The attack mutates the same inode.")
    }

    func testPhotoProjectCannotSealWithoutSelectionEvidence() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: "Missing Photo Evidence",
            projectID: id
        )
        var metadata = try Self.prepareMixedInputs(
            in: transaction.bundleURL,
            id: id,
            title: "Missing Photo Evidence",
            checkpoint: { _ in }
        )
        try FileManager.default.removeItem(
            at: ProjectPaths(root: transaction.bundleURL).photoSelectionArtifactURL
        )
        metadata.photoSelectionReceipt = nil
        try Self.writeUncheckedMetadata(
            metadata,
            to: ProjectPaths(root: transaction.bundleURL).metadataURL
        )

        XCTAssertThrowsError(try transaction.validateAndSeal(expectedMetadata: metadata)) {
            XCTAssertEqual($0 as? ProjectPublicationError, .invalidInitialMetadata)
        }
    }

    func testMixedPhotoPublicationPreservesExactSelectionSidecar() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: "Published Photo Evidence",
            projectID: id
        )
        let metadata = try Self.prepareMixedInputs(
            in: transaction.bundleURL,
            id: id,
            title: "Published Photo Evidence",
            checkpoint: { try transaction.reached($0) }
        )
        let expectedBytes = try Data(
            contentsOf: ProjectPaths(root: transaction.bundleURL)
                .photoSelectionArtifactURL
        )

        try transaction.validateAndSeal(expectedMetadata: metadata)
        let published = try transaction.publish()

        let paths = ProjectPaths(root: published)
        XCTAssertEqual(try Data(contentsOf: paths.photoSelectionArtifactURL), expectedBytes)
        XCTAssertEqual(try permissions(at: paths.photoSelectionArtifactURL), 0o600)
        XCTAssertEqual(
            try ProjectMetadataStore.load(from: paths.metadataURL).photoSelectionReceipt,
            metadata.photoSelectionReceipt
        )
    }

    func testPublicationReceiptDigestBindsPhotoSourceRankAndSelectionSidecar() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: "Photo Receipt Digest",
            projectID: id
        )
        defer { try? transaction.abort() }
        let metadata = try Self.prepareMixedInputs(
            in: transaction.bundleURL,
            id: id,
            title: "Photo Receipt Digest",
            checkpoint: { _ in }
        )
        let baseline = ProjectPublicationTransaction.inputReceiptDigestForTesting(metadata)
        let originalPhoto = try XCTUnwrap(metadata.photoInputReceipts?.first)
        let originalSelection = try XCTUnwrap(metadata.photoSelectionReceipt)

        var sourceMutation = metadata
        sourceMutation.photoInputReceipts = [Self.photoReceipt(
            replacing: originalPhoto,
            sourceSHA256: String(repeating: "a", count: 64),
            retainedRank: originalPhoto.retainedRank
        )]
        var rankMutation = metadata
        rankMutation.photoInputReceipts = [Self.photoReceipt(
            replacing: originalPhoto,
            sourceSHA256: originalPhoto.source.sha256,
            retainedRank: originalPhoto.retainedRank + 1
        )]
        var sidecarMutation = metadata
        sidecarMutation.photoSelectionReceipt = Self.selectionReceipt(
            replacing: originalSelection,
            byteCount: originalSelection.byteCount,
            sha256: String(repeating: "b", count: 64)
        )
        var sidecarSizeMutation = metadata
        sidecarSizeMutation.photoSelectionReceipt = Self.selectionReceipt(
            replacing: originalSelection,
            byteCount: originalSelection.byteCount + 1,
            sha256: originalSelection.sha256
        )
        var sidecarPathMutation = metadata
        sidecarPathMutation.photoSelectionReceipt = Self.selectionReceipt(
            replacing: originalSelection,
            projectRelativePath: "Frames/other-selection.json",
            byteCount: originalSelection.byteCount,
            sha256: originalSelection.sha256
        )

        XCTAssertNotEqual(
            ProjectPublicationTransaction.inputReceiptDigestForTesting(sourceMutation),
            baseline
        )
        XCTAssertNotEqual(
            ProjectPublicationTransaction.inputReceiptDigestForTesting(rankMutation),
            baseline
        )
        XCTAssertNotEqual(
            ProjectPublicationTransaction.inputReceiptDigestForTesting(sidecarMutation),
            baseline
        )
        XCTAssertNotEqual(
            ProjectPublicationTransaction.inputReceiptDigestForTesting(sidecarSizeMutation),
            baseline
        )
        XCTAssertNotEqual(
            ProjectPublicationTransaction.inputReceiptDigestForTesting(sidecarPathMutation),
            baseline
        )
    }

    func testOversizedPhotoSelectionEvidenceCannotSealEvenWithMatchingReceipt() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: "Oversized Photo Evidence",
            projectID: id
        )
        var metadata = try Self.prepareMixedInputs(
            in: transaction.bundleURL,
            id: id,
            title: "Oversized Photo Evidence",
            checkpoint: { _ in }
        )
        let paths = ProjectPaths(root: transaction.bundleURL)
        let oversized = Data(
            repeating: 0x61,
            count: PhotoSelectionArtifactStore.maximumArtifactBytes + 1
        )
        try oversized.write(to: paths.photoSelectionArtifactURL, options: .atomic)
        XCTAssertEqual(chmod(paths.photoSelectionArtifactURL.path, 0o600), 0)
        let prior = try XCTUnwrap(metadata.photoSelectionReceipt)
        metadata.photoSelectionReceipt = Self.selectionReceipt(
            replacing: prior,
            byteCount: Int64(oversized.count),
            sha256: Self.sha256(oversized)
        )
        try Self.writeUncheckedMetadata(metadata, to: paths.metadataURL)

        XCTAssertThrowsError(try transaction.validateAndSeal(expectedMetadata: metadata)) {
            XCTAssertEqual($0 as? ProjectPublicationError, .invalidInitialMetadata)
        }
    }

    func testPhotoSelectionSymlinkCannotSeal() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: "Symlink Photo Evidence",
            projectID: id
        )
        defer { try? transaction.abort() }
        let metadata = try Self.prepareMixedInputs(
            in: transaction.bundleURL,
            id: id,
            title: "Symlink Photo Evidence",
            checkpoint: { _ in }
        )
        let sidecar = ProjectPaths(root: transaction.bundleURL).photoSelectionArtifactURL
        let outside = base.appendingPathComponent("outside-selection.json")
        try FileManager.default.moveItem(at: sidecar, to: outside)
        XCTAssertEqual(symlink(outside.path, sidecar.path), 0)

        XCTAssertThrowsError(try transaction.validateAndSeal(expectedMetadata: metadata))
    }

    func testTamperedPhotoSelectionEvidenceCannotSeal() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: "Tampered Photo Evidence",
            projectID: id
        )
        defer { try? transaction.abort() }
        let metadata = try Self.prepareMixedInputs(
            in: transaction.bundleURL,
            id: id,
            title: "Tampered Photo Evidence",
            checkpoint: { _ in }
        )
        let sidecar = ProjectPaths(root: transaction.bundleURL).photoSelectionArtifactURL
        var bytes = try Data(contentsOf: sidecar)
        bytes[bytes.startIndex] ^= 0xff
        try bytes.write(to: sidecar, options: .atomic)
        XCTAssertEqual(chmod(sidecar.path, 0o600), 0)

        XCTAssertThrowsError(try transaction.validateAndSeal(expectedMetadata: metadata)) {
            XCTAssertEqual($0 as? ProjectPublicationError, .invalidInitialMetadata)
        }
    }

    func testPhotoSelectionMutationAtPublicationCheckpointsFailsClosed() throws {
        for attackedCheckpoint in [
            ProjectPublicationTransaction.Checkpoint.initialMetadataValidated,
            .inputContentHashed,
            .metadataDurable,
        ] {
            let base = temporaryDirectory(suffix: attackedCheckpoint.rawValue)
            defer { try? FileManager.default.removeItem(at: base) }
            let sidecarBox = LockedURLBox()
            let id = UUID()
            let transaction = try ProjectPublicationTransaction.begin(
                in: base,
                title: "Photo Evidence Race",
                projectID: id,
                checkpointHandler: { checkpoint in
                    guard checkpoint == attackedCheckpoint,
                          let sidecar = sidecarBox.value else { return }
                    let handle = try FileHandle(forWritingTo: sidecar)
                    defer { try? handle.close() }
                    try handle.seek(toOffset: 0)
                    try handle.write(contentsOf: Data("forged".utf8))
                    try handle.synchronize()
                }
            )
            defer { try? transaction.abort() }
            let metadata = try Self.prepareMixedInputs(
                in: transaction.bundleURL,
                id: id,
                title: "Photo Evidence Race",
                checkpoint: { try transaction.reached($0) }
            )
            sidecarBox.value = ProjectPaths(root: transaction.bundleURL)
                .photoSelectionArtifactURL

            XCTAssertThrowsError(try transaction.validateAndSeal(expectedMetadata: metadata)) {
                XCTAssertTrue(
                    ($0 as? ProjectPublicationError) == .pendingBundleChanged
                        || ($0 as? ProjectPublicationError) == .invalidInitialMetadata,
                    "Unexpected error at \(attackedCheckpoint.rawValue): \($0)"
                )
            }
        }
    }

    func testByteIdenticalPhotoSelectionReplacementAfterVerificationCannotSeal() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let sidecarBox = LockedURLBox()
        let replacementIdentityBox = LockedTestIdentityBox()
        let id = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: "Photo Evidence Identity Race",
            projectID: id,
            checkpointHandler: { checkpoint in
                guard checkpoint == .initialMetadataValidated,
                      let sidecar = sidecarBox.value else { return }
                let bytes = try Data(contentsOf: sidecar)
                let replacement = sidecar.deletingLastPathComponent()
                    .appendingPathComponent("replacement-photo-selection.json")
                try bytes.write(to: replacement, options: .atomic)
                guard chmod(replacement.path, S_IRUSR | S_IWUSR) == 0,
                      Darwin.rename(replacement.path, sidecar.path) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                var replacementStatus = stat()
                guard lstat(sidecar.path, &replacementStatus) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                replacementIdentityBox.value = TestIdentity(
                    device: UInt64(replacementStatus.st_dev),
                    inode: UInt64(replacementStatus.st_ino)
                )
            }
        )
        let metadata = try Self.prepareMixedInputs(
            in: transaction.bundleURL,
            id: id,
            title: "Photo Evidence Identity Race",
            checkpoint: { try transaction.reached($0) }
        )
        let sidecar = ProjectPaths(root: transaction.bundleURL).photoSelectionArtifactURL
        let originalIdentity = try identity(at: sidecar)
        sidecarBox.value = sidecar

        XCTAssertThrowsError(try transaction.validateAndSeal(expectedMetadata: metadata)) {
            XCTAssertEqual($0 as? ProjectPublicationError, .pendingBundleChanged)
        }
        XCTAssertNotEqual(try XCTUnwrap(replacementIdentityBox.value), originalIdentity)
    }

    func testPhotoSelectionFramesDirectoryReplacementAfterVerificationCannotSeal() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let sidecarBox = LockedURLBox()
        let replacementIdentityBox = LockedTestIdentityBox()
        let id = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: "Photo Evidence Directory Race",
            projectID: id,
            checkpointHandler: { checkpoint in
                guard checkpoint == .initialMetadataValidated,
                      let sidecar = sidecarBox.value else { return }
                let frames = sidecar.deletingLastPathComponent()
                let heldFrames = frames.deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("held-frames", isDirectory: true)
                guard Darwin.rename(frames.path, heldFrames.path) == 0,
                      mkdir(frames.path, S_IRWXU) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                for source in try FileManager.default.contentsOfDirectory(
                    at: heldFrames,
                    includingPropertiesForKeys: nil
                ) {
                    let destination = frames.appendingPathComponent(source.lastPathComponent)
                    guard Darwin.rename(source.path, destination.path) == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                }
                var replacementStatus = stat()
                guard lstat(frames.path, &replacementStatus) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                replacementIdentityBox.value = TestIdentity(
                    device: UInt64(replacementStatus.st_dev),
                    inode: UInt64(replacementStatus.st_ino)
                )
            }
        )
        let metadata = try Self.prepareMixedInputs(
            in: transaction.bundleURL,
            id: id,
            title: "Photo Evidence Directory Race",
            checkpoint: { try transaction.reached($0) }
        )
        let sidecar = ProjectPaths(root: transaction.bundleURL).photoSelectionArtifactURL
        let frames = sidecar.deletingLastPathComponent()
        let originalIdentity = try identity(at: frames)
        let originalSidecarIdentity = try identity(at: sidecar)
        sidecarBox.value = sidecar

        XCTAssertThrowsError(try transaction.validateAndSeal(expectedMetadata: metadata)) {
            XCTAssertEqual($0 as? ProjectPublicationError, .pendingBundleChanged)
        }
        XCTAssertNotEqual(try XCTUnwrap(replacementIdentityBox.value), originalIdentity)
        XCTAssertEqual(try identity(at: sidecar), originalSidecarIdentity)
    }

    func testPhotoSelectionMutationAfterReadyReceiptPreventsPublish() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let sidecarBox = LockedURLBox()
        let id = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: "Ready Photo Evidence Race",
            projectID: id,
            checkpointHandler: { checkpoint in
                guard checkpoint == .readyReceiptDurable,
                      let sidecar = sidecarBox.value else { return }
                let handle = try FileHandle(forWritingTo: sidecar)
                defer { try? handle.close() }
                try handle.seek(toOffset: 0)
                try handle.write(contentsOf: Data("forged".utf8))
                try handle.synchronize()
            }
        )
        defer { try? transaction.abort() }
        let metadata = try Self.prepareMixedInputs(
            in: transaction.bundleURL,
            id: id,
            title: "Ready Photo Evidence Race",
            checkpoint: { try transaction.reached($0) }
        )
        sidecarBox.value = ProjectPaths(root: transaction.bundleURL)
            .photoSelectionArtifactURL

        try transaction.validateAndSeal(expectedMetadata: metadata)
        XCTAssertThrowsError(try transaction.publish())
        XCTAssertTrue(try visibleProjects(in: base).isEmpty)
    }

    func testEmptyMixedPhotoRootMayPublishOnlyWithAuthenticatedVideo() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: "Video With Empty Photo Root",
            projectID: id
        )
        let metadata = try Self.makeEmptyMixedInitialProject(
            in: transaction.bundleURL,
            id: id,
            title: "Video With Empty Photo Root"
        )

        try transaction.validateAndSeal(expectedMetadata: metadata)
        let published = try transaction.publish()

        XCTAssertEqual(
            try ProjectMetadataStore.load(
                from: ProjectPaths(root: published).metadataURL
            ).videoInputReceipts?.count,
            1
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ProjectPaths(root: published).photoSelectionArtifactURL.path
            )
        )
    }

    func testEmptyMixedPhotoRootCannotSealWithoutAuthenticatedVideo() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: "Unauthenticated Empty Mixed Input",
            projectID: id
        )
        var metadata = try Self.makeEmptyMixedInitialProject(
            in: transaction.bundleURL,
            id: id,
            title: "Unauthenticated Empty Mixed Input"
        )
        metadata.videoInputReceipts = []
        try Self.writeUncheckedMetadata(
            metadata,
            to: ProjectPaths(root: transaction.bundleURL).metadataURL
        )

        XCTAssertThrowsError(try transaction.validateAndSeal(expectedMetadata: metadata)) {
            XCTAssertEqual($0 as? ProjectPublicationError, .invalidInitialMetadata)
        }
    }

    func testReadyValidationRejectsPermissionDriftWithoutRepairingIt() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: "Permission Drift",
            projectID: id
        )
        defer { try? transaction.abort() }
        let metadata = try Self.makeInitialProject(
            in: transaction.bundleURL,
            id: id,
            title: "Permission Drift"
        )
        try transaction.validateAndSeal(expectedMetadata: metadata)
        let metadataURL = ProjectPaths(root: transaction.bundleURL).metadataURL
        XCTAssertEqual(chmod(metadataURL.path, S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH), 0)

        XCTAssertThrowsError(try transaction.publish())
        XCTAssertEqual(try permissions(at: metadataURL), 0o644)
    }

    func testSealingDoesNotAccumulateOneDescriptorPerInput() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let hashCount = LockedInt()
        let id = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: "Many Inputs",
            projectID: id,
            checkpointHandler: { checkpoint in
                if checkpoint == .inputContentHashed { hashCount.increment() }
            }
        )
        let metadata = try Self.makeManyVideoProject(
            in: transaction.bundleURL,
            id: id,
            title: "Many Inputs",
            count: 300
        )

        try transaction.validateAndSeal(expectedMetadata: metadata)
        let published = try transaction.publish()

        XCTAssertEqual(
            try ProjectMetadataStore.load(from: ProjectPaths(root: published).metadataURL)
                .videoInputReceipts?.count,
            300
        )
        XCTAssertEqual(hashCount.value, 1)
    }

    func testCollisionRetriesSameStagedBundleWithoutReplacingVisibleProject() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let id = UUID()
        let title = "Property Exterior"
        let occupied = ProjectPublicationTransaction.candidateURL(
            in: base,
            title: title,
            attempt: 0
        )
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
        let sentinel = occupied.appendingPathComponent("owned-by-existing-project")
        try Data("keep".utf8).write(to: sentinel)
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: title,
            projectID: id
        )
        let metadata = try Self.makeInitialProject(
            in: transaction.bundleURL,
            id: id,
            title: title
        )
        let inputURL = transaction.bundleURL.appendingPathComponent("Originals/video-0000.mov")
        let inputIdentity = try identity(at: inputURL)

        try transaction.validateAndSeal(expectedMetadata: metadata)
        let published = try transaction.publish()

        XCTAssertEqual(published.lastPathComponent, ProjectPublicationTransaction.candidateURL(
            in: transaction.baseURL,
            title: title,
            attempt: 1
        ).lastPathComponent)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertEqual(try identity(at: published.appendingPathComponent("Originals/video-0000.mov")), inputIdentity)
    }

    func testCrashBeforeMetadataRemovesOnlyRecognizedIncompleteTransaction() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        var transaction: ProjectPublicationTransaction? = try ProjectPublicationTransaction.begin(
            in: base,
            title: "Interrupted",
            projectID: UUID()
        )
        let envelope = try XCTUnwrap(transaction?.envelopeURL)
        transaction = nil

        let events = ProjectPublicationTransaction.reconcile(in: base)

        XCTAssertTrue(events.contains(.removedIncomplete(envelope)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: envelope.path))
        XCTAssertTrue(try visibleProjects(in: base).isEmpty)
    }

    func testMetadataDurableCrashPublishesOnlyTransactionBoundBundle() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID()
        var transaction: ProjectPublicationTransaction? = try ProjectPublicationTransaction.begin(
            in: base,
            title: "Durable Metadata",
            projectID: id,
            checkpointHandler: { checkpoint in
                if checkpoint == .metadataDurable { throw InjectedCrash() }
            }
        )
        let metadata = try Self.makeInitialProject(
            in: try XCTUnwrap(transaction?.bundleURL),
            id: id,
            title: "Durable Metadata"
        )
        XCTAssertThrowsError(try transaction?.validateAndSeal(expectedMetadata: metadata)) {
            XCTAssertTrue($0 is InjectedCrash)
        }
        XCTAssertTrue(try visibleProjects(in: base).isEmpty)
        transaction = nil

        let events = ProjectPublicationTransaction.reconcile(in: base)

        guard case .published(let published)? = events.first(where: {
            if case .published = $0 { return true }
            return false
        }) else {
            return XCTFail("Expected a transaction-bound recovered publication, got \(events)")
        }
        XCTAssertEqual(
            try ProjectMetadataStore.load(from: ProjectPaths(root: published).metadataURL).id,
            id
        )
    }

    func testPreReadyRecoveryRejectsMetadataRewrittenAfterValidation() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID()
        var transaction: ProjectPublicationTransaction? = try ProjectPublicationTransaction.begin(
            in: base,
            title: "Bound Metadata",
            projectID: id,
            checkpointHandler: { checkpoint in
                if checkpoint == .initialMetadataValidated { throw InjectedCrash() }
            }
        )
        let bundle = try XCTUnwrap(transaction?.bundleURL)
        let metadata = try Self.makeInitialProject(
            in: bundle,
            id: id,
            title: "Bound Metadata"
        )
        XCTAssertThrowsError(try transaction?.validateAndSeal(expectedMetadata: metadata))
        var rewritten = metadata
        rewritten.notes = "rewritten after the durable validation boundary"
        try ProjectMetadataStore.save(
            rewritten,
            to: ProjectPaths(root: bundle).metadataURL
        )
        let envelope = try XCTUnwrap(transaction?.envelopeURL)
        transaction = nil

        let events = ProjectPublicationTransaction.reconcile(in: base)

        XCTAssertTrue(events.contains(where: {
            if case .preserved(let url, _) = $0 { return url == envelope }
            return false
        }), "Expected rewritten metadata to be preserved for inspection: \(events)")
        XCTAssertTrue(try visibleProjects(in: base).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: envelope.path))
    }

    func testChildRecoveryPreservesReplacedInputWithoutChangingItsMode() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let crash = try runCrashHelper(
            mode: "publish",
            base: base,
            checkpoint: .initialMetadataValidated
        )
        XCTAssertEqual(crash.terminationStatus, 86)

        let envelope = try XCTUnwrap(try transactionEnvelopes(in: base).first)
        let input = envelope.appendingPathComponent(
            "project.easysplatproj/Originals/video-0000.mov"
        )
        try FileManager.default.removeItem(at: input)
        let replacement = Data("replacement-after-validation".utf8)
        try replacement.write(to: input)
        XCTAssertEqual(chmod(input.path, 0o644), 0)
        let replacementIdentity = try identity(at: input)

        let marker = base.appendingPathComponent("reconcile-marker")
        let reconcile = try runReconcileHelper(base: base, marker: marker)

        XCTAssertEqual(reconcile.terminationStatus, 0)
        XCTAssertTrue(try visibleProjects(in: base).isEmpty)
        XCTAssertEqual(try identity(at: input), replacementIdentity)
        XCTAssertEqual(try permissions(at: input), 0o644)
        XCTAssertEqual(try Data(contentsOf: input), replacement)
        XCTAssertTrue(FileManager.default.fileExists(atPath: envelope.path))
    }

    func testChildCrashBeforeBundleEvidencePreservesUnexpectedBundle() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let crash = try runCrashHelper(
            mode: "publish",
            base: base,
            checkpoint: .transactionRecordDurable
        )
        XCTAssertEqual(crash.terminationStatus, 86)

        let envelope = try XCTUnwrap(try transactionEnvelopes(in: base).first)
        let unexpectedBundle = envelope.appendingPathComponent(
            "project.easysplatproj",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: unexpectedBundle,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let replacementIdentity = try identity(at: unexpectedBundle)

        let marker = base.appendingPathComponent("reconcile-marker")
        let reconcile = try runReconcileHelper(base: base, marker: marker)

        XCTAssertEqual(reconcile.terminationStatus, 0)
        XCTAssertEqual(try identity(at: unexpectedBundle), replacementIdentity)
        XCTAssertEqual(try permissions(at: unexpectedBundle), 0o700)
        XCTAssertTrue(FileManager.default.fileExists(atPath: envelope.path))
        XCTAssertTrue(try visibleProjects(in: base).isEmpty)
    }

    func testChildCrashAfterBundleEvidencePreservesReplacedBundle() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let crash = try runCrashHelper(
            mode: "publish",
            base: base,
            checkpoint: .bundleDirectoryCreated
        )
        XCTAssertEqual(crash.terminationStatus, 86)

        let envelope = try XCTUnwrap(try transactionEnvelopes(in: base).first)
        let bundle = envelope.appendingPathComponent("project.easysplatproj", isDirectory: true)
        let originalIdentity = try identity(at: bundle)
        try FileManager.default.removeItem(at: bundle)
        try FileManager.default.createDirectory(
            at: bundle,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let replacementIdentity = try identity(at: bundle)
        XCTAssertNotEqual(replacementIdentity, originalIdentity)

        let marker = base.appendingPathComponent("reconcile-marker")
        let reconcile = try runReconcileHelper(base: base, marker: marker)

        XCTAssertEqual(reconcile.terminationStatus, 0)
        XCTAssertEqual(try identity(at: bundle), replacementIdentity)
        XCTAssertEqual(try permissions(at: bundle), 0o700)
        XCTAssertTrue(FileManager.default.fileExists(atPath: envelope.path))
        XCTAssertTrue(try visibleProjects(in: base).isEmpty)
    }

    func testChildCrashAfterAdoptionPreservesReplacedInputIdentity() throws {
        let cases: [(ProjectPublicationTransaction.Checkpoint, String, Data)] = [
            (.videoAdopted, "Originals/video-0000.mov", Data("other-video".utf8)),
            (.photosAdopted, "Originals/Photos/photo-0000.jpg", Data("other-photo".utf8)),
        ]
        for (checkpoint, relativePath, replacement) in cases {
            let base = temporaryDirectory(suffix: checkpoint.rawValue)
            defer { try? FileManager.default.removeItem(at: base) }
            let crash = try runCrashHelper(
                mode: "publish",
                base: base,
                checkpoint: checkpoint
            )
            XCTAssertEqual(crash.terminationStatus, 86, checkpoint.rawValue)

            let envelope = try XCTUnwrap(try transactionEnvelopes(in: base).first)
            let input = envelope
                .appendingPathComponent("project.easysplatproj", isDirectory: true)
                .appendingPathComponent(relativePath)
            let originalIdentity = try identity(at: input)
            try FileManager.default.removeItem(at: input)
            try replacement.write(to: input)
            XCTAssertEqual(chmod(input.path, S_IRUSR | S_IWUSR), 0)
            let replacementIdentity = try identity(at: input)
            XCTAssertNotEqual(replacementIdentity, originalIdentity)

            let marker = base.appendingPathComponent("reconcile-marker")
            let reconcile = try runReconcileHelper(base: base, marker: marker)

            XCTAssertEqual(reconcile.terminationStatus, 0, checkpoint.rawValue)
            XCTAssertEqual(try identity(at: input), replacementIdentity, checkpoint.rawValue)
            XCTAssertEqual(try permissions(at: input), 0o600, checkpoint.rawValue)
            XCTAssertEqual(try Data(contentsOf: input), replacement, checkpoint.rawValue)
            XCTAssertTrue(FileManager.default.fileExists(atPath: envelope.path), checkpoint.rawValue)
            XCTAssertTrue(try visibleProjects(in: base).isEmpty, checkpoint.rawValue)
        }
    }

    func testCrashAfterExclusiveRenameCleansReceiptWithoutTouchingVisibleBundle() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID()
        var transaction: ProjectPublicationTransaction? = try ProjectPublicationTransaction.begin(
            in: base,
            title: "Rename Crash",
            projectID: id,
            checkpointHandler: { checkpoint in
                if checkpoint == .renameComplete { throw InjectedCrash() }
            }
        )
        let metadata = try Self.makeInitialProject(
            in: try XCTUnwrap(transaction?.bundleURL),
            id: id,
            title: "Rename Crash"
        )
        try transaction?.validateAndSeal(expectedMetadata: metadata)
        XCTAssertThrowsError(try transaction?.publish()) { XCTAssertTrue($0 is InjectedCrash) }
        let visible = try XCTUnwrap(try visibleProjects(in: base).first)
        let visibleIdentity = try identity(at: visible)
        transaction = nil

        let events = ProjectPublicationTransaction.reconcile(in: base)

        XCTAssertTrue(events.contains(where: {
            guard case .cleanedPublished(let recovered) = $0 else { return false }
            return recovered.lastPathComponent == visible.lastPathComponent
                && (try? identity(at: recovered)) == visibleIdentity
        }), "Unexpected reconciliation events: \(events)")
        XCTAssertEqual(try identity(at: visible), visibleIdentity)
        XCTAssertEqual(
            try ProjectMetadataStore.load(from: ProjectPaths(root: visible).metadataURL).id,
            id
        )
    }

    func testCrashAfterRenamePreservesReceiptWhenVisibleBundleChanges() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let id = UUID()
        var transaction: ProjectPublicationTransaction? = try ProjectPublicationTransaction.begin(
            in: base,
            title: "Changed After Rename",
            projectID: id,
            checkpointHandler: { checkpoint in
                if checkpoint == .renameComplete { throw InjectedCrash() }
            }
        )
        let metadata = try Self.makeInitialProject(
            in: try XCTUnwrap(transaction?.bundleURL),
            id: id,
            title: "Changed After Rename"
        )
        try transaction?.validateAndSeal(expectedMetadata: metadata)
        XCTAssertThrowsError(try transaction?.publish())
        let visible = try XCTUnwrap(try visibleProjects(in: base).first)
        var changed = try ProjectMetadataStore.load(
            from: ProjectPaths(root: visible).metadataURL
        )
        changed.notes = "changed after publication rename"
        try ProjectMetadataStore.save(changed, to: ProjectPaths(root: visible).metadataURL)
        transaction = nil

        let events = ProjectPublicationTransaction.reconcile(in: base)

        XCTAssertTrue(events.contains(where: {
            if case .preserved = $0 { return true }
            return false
        }))
        let container = base.appendingPathComponent(
            ProjectPublicationTransaction.containerName,
            isDirectory: true
        )
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: container.path)
            .contains(where: { $0.hasPrefix("txn-") }))
        XCTAssertEqual(
            try ProjectMetadataStore.load(from: ProjectPaths(root: visible).metadataURL).notes,
            "changed after publication rename"
        )
    }

    func testForgedEmptyQuarantineWithoutCleanupReceiptIsPreserved() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let container = base.appendingPathComponent(
            ProjectPublicationTransaction.containerName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let forged = container.appendingPathComponent(
            ".deleting-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: forged,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        let events = ProjectPublicationTransaction.reconcile(in: base)

        XCTAssertTrue(events.contains(where: {
            if case .preserved(let url, _) = $0 {
                return url.resolvingSymlinksInPath().path
                    == forged.resolvingSymlinksInPath().path
            }
            return false
        }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: forged.path))
    }

    func testPublishedCleanupReceiptDoesNotDeleteBundleMovedBackIntoEnvelope() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let crash = try runCrashHelper(
            mode: "publish",
            base: base,
            checkpoint: .cleanupIntentDurable
        )
        XCTAssertEqual(crash.terminationStatus, 86)

        let visible = try XCTUnwrap(try visibleProjects(in: base).first)
        let publishedIdentity = try identity(at: visible)
        let envelope = try XCTUnwrap(try transactionEnvelopes(in: base).first)
        let hiddenBundle = envelope.appendingPathComponent(
            "project.easysplatproj",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: visible, to: hiddenBundle)
        XCTAssertEqual(try identity(at: hiddenBundle), publishedIdentity)

        let marker = base.appendingPathComponent("reconcile-marker")
        let reconcile = try runReconcileHelper(base: base, marker: marker)

        XCTAssertEqual(reconcile.terminationStatus, 0)
        XCTAssertTrue(try visibleProjects(in: base).isEmpty)
        XCTAssertEqual(try identity(at: hiddenBundle), publishedIdentity)
        XCTAssertTrue(FileManager.default.fileExists(atPath: envelope.path))
    }

    func testPublishedCleanupReceiptMustMatchTransactionValidationEvidence() throws {
        for mutation in ["metadata", "receipts", "manifest"] {
            let base = temporaryDirectory(suffix: mutation)
            defer { try? FileManager.default.removeItem(at: base) }
            let crash = try runCrashHelper(
                mode: "publish",
                base: base,
                checkpoint: .cleanupIntentDurable
            )
            XCTAssertEqual(crash.terminationStatus, 86, mutation)

            let visible = try XCTUnwrap(try visibleProjects(in: base).first)
            let visibleIdentity = try identity(at: visible)
            let envelope = try XCTUnwrap(try transactionEnvelopes(in: base).first)
            let container = base.appendingPathComponent(
                ProjectPublicationTransaction.containerName,
                isDirectory: true
            )
            let cleanupReceipt = try XCTUnwrap(
                FileManager.default.contentsOfDirectory(
                    at: container,
                    includingPropertiesForKeys: nil
                ).first(where: {
                    $0.lastPathComponent.hasPrefix(".cleanup-")
                        && $0.pathExtension == "json"
                })
            )
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(contentsOf: cleanupReceipt))
                    as? [String: Any]
            )
            var ready = try XCTUnwrap(object["readyRecord"] as? [String: Any])
            switch mutation {
            case "metadata":
                ready["metadataSHA256"] = String(repeating: "0", count: 64)
            case "receipts":
                ready["receiptDigest"] = String(repeating: "0", count: 64)
            default:
                var manifest = try XCTUnwrap(ready["manifest"] as? [[String: Any]])
                let index = try XCTUnwrap(manifest.firstIndex(where: {
                    $0["relativePath"] as? String == "project.json"
                }))
                manifest[index]["sha256"] = String(repeating: "0", count: 64)
                ready["manifest"] = manifest
            }
            object["readyRecord"] = ready
            let forged = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try forged.write(to: cleanupReceipt, options: .atomic)
            XCTAssertEqual(chmod(cleanupReceipt.path, S_IRUSR | S_IWUSR), 0)

            let marker = base.appendingPathComponent("reconcile-marker")
            let reconcile = try runReconcileHelper(base: base, marker: marker)

            XCTAssertEqual(reconcile.terminationStatus, 0, mutation)
            XCTAssertEqual(try identity(at: visible), visibleIdentity, mutation)
            XCTAssertTrue(FileManager.default.fileExists(atPath: envelope.path), mutation)
            XCTAssertTrue(FileManager.default.fileExists(atPath: cleanupReceipt.path), mutation)
        }
    }

    func testAbortCleanupReceiptPreservesReplacedControlledInput() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let crash = try runCrashHelper(
            mode: "abort-unsealed",
            base: base,
            checkpoint: .cleanupIntentDurable
        )
        XCTAssertEqual(crash.terminationStatus, 86)

        let envelope = try XCTUnwrap(try transactionEnvelopes(in: base).first)
        let input = envelope.appendingPathComponent(
            "project.easysplatproj/Originals/video-0000.mov"
        )
        let originalIdentity = try identity(at: input)
        try FileManager.default.removeItem(at: input)
        let replacement = Data("replacement-owned-by-someone-else".utf8)
        try replacement.write(to: input)
        XCTAssertEqual(chmod(input.path, S_IRUSR | S_IWUSR), 0)
        let replacementIdentity = try identity(at: input)
        XCTAssertNotEqual(replacementIdentity, originalIdentity)

        let marker = base.appendingPathComponent("reconcile-marker")
        let reconcile = try runReconcileHelper(base: base, marker: marker)

        XCTAssertEqual(reconcile.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: input), replacement)
        XCTAssertEqual(try identity(at: input), replacementIdentity)
        XCTAssertTrue(FileManager.default.fileExists(atPath: envelope.path))
    }

    func testAbortCleanupReceiptPreservesReplacedPhotoSelectionEvidence() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let crash = try runCrashHelper(
            mode: "abort-unsealed",
            base: base,
            checkpoint: .cleanupIntentDurable
        )
        XCTAssertEqual(crash.terminationStatus, 86)

        let envelope = try XCTUnwrap(try transactionEnvelopes(in: base).first)
        let sidecar = envelope.appendingPathComponent(
            "project.easysplatproj/Frames/photo_selection.json"
        )
        let originalIdentity = try identity(at: sidecar)
        try FileManager.default.removeItem(at: sidecar)
        let replacement = Data("replacement-photo-selection-evidence".utf8)
        try replacement.write(to: sidecar)
        XCTAssertEqual(chmod(sidecar.path, S_IRUSR | S_IWUSR), 0)
        let replacementIdentity = try identity(at: sidecar)
        XCTAssertNotEqual(replacementIdentity, originalIdentity)

        let marker = base.appendingPathComponent("reconcile-marker")
        let reconcile = try runReconcileHelper(base: base, marker: marker)

        XCTAssertEqual(reconcile.terminationStatus, 0)
        XCTAssertEqual(try Data(contentsOf: sidecar), replacement)
        XCTAssertEqual(try identity(at: sidecar), replacementIdentity)
        XCTAssertTrue(FileManager.default.fileExists(atPath: envelope.path))
    }

    func testCleanupReconciliationRejectsFIFOControlFileWithoutBlocking() throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let crash = try runCrashHelper(
            mode: "abort-sealed",
            base: base,
            checkpoint: .cleanupIntentDurable
        )
        XCTAssertEqual(crash.terminationStatus, 86)

        let envelope = try XCTUnwrap(try transactionEnvelopes(in: base).first)
        let ready = envelope.appendingPathComponent("ready.json")
        try FileManager.default.removeItem(at: ready)
        XCTAssertEqual(mkfifo(ready.path, S_IRUSR | S_IWUSR), 0)

        let marker = base.appendingPathComponent("reconcile-marker")
        let reconcile = try runReconcileHelper(base: base, marker: marker)

        XCTAssertEqual(reconcile.terminationStatus, 0)
        var status = stat()
        XCTAssertEqual(lstat(ready.path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFIFO)
        XCTAssertTrue(FileManager.default.fileExists(atPath: envelope.path))
    }

    func testPublishRejectsReboundLibraryPathBeforeExclusiveRename() throws {
        let base = temporaryDirectory()
        let moved = base.deletingLastPathComponent().appendingPathComponent(
            "\(base.lastPathComponent)-moved",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: base)
            try? FileManager.default.removeItem(at: moved)
        }
        let id = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: "Rebound Library",
            projectID: id
        )
        let metadata = try Self.makeInitialProject(
            in: transaction.bundleURL,
            id: id,
            title: "Rebound Library"
        )
        try transaction.validateAndSeal(expectedMetadata: metadata)
        try FileManager.default.moveItem(at: base, to: moved)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)

        XCTAssertThrowsError(try transaction.publish()) {
            XCTAssertEqual($0 as? ProjectPublicationError, .transactionIdentityChanged)
        }
        XCTAssertTrue(try visibleProjects(in: base).isEmpty)
        XCTAssertTrue(try visibleProjects(in: moved).isEmpty)
        XCTAssertFalse(try transactionEnvelopes(in: moved).isEmpty)
    }

    func testUnknownSymlinkAndHardlinkRemnantsArePreserved() throws {
        for hostileKind in HostileKind.allCases {
            let base = temporaryDirectory(suffix: hostileKind.rawValue)
            defer { try? FileManager.default.removeItem(at: base) }
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let outside = base.appendingPathComponent("outside")
            try Data("never delete".utf8).write(to: outside)
            var transaction: ProjectPublicationTransaction? = try ProjectPublicationTransaction.begin(
                in: base,
                title: "Hostile \(hostileKind.rawValue)",
                projectID: UUID()
            )
            let envelope = try XCTUnwrap(transaction?.envelopeURL)
            let bundle = try XCTUnwrap(transaction?.bundleURL)
            switch hostileKind {
            case .unknown:
                try Data("unknown".utf8).write(to: bundle.appendingPathComponent("mystery.bin"))
            case .framesFile:
                let frames = bundle.appendingPathComponent("Frames", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: frames,
                    withIntermediateDirectories: false
                )
                try Data("unowned".utf8).write(
                    to: frames.appendingPathComponent("other-selection.json")
                )
            case .symlink:
                try FileManager.default.createSymbolicLink(
                    at: bundle.appendingPathComponent("mystery-link"),
                    withDestinationURL: outside
                )
            case .hardlink:
                let originals = bundle.appendingPathComponent("Originals", isDirectory: true)
                try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: false)
                XCTAssertEqual(
                    link(outside.path, originals.appendingPathComponent("video-0000.mov").path),
                    0
                )
            case .fifo:
                XCTAssertEqual(
                    mkfifo(bundle.appendingPathComponent("mystery-pipe").path, S_IRUSR | S_IWUSR),
                    0
                )
            case .unicodeDigits:
                let originals = bundle.appendingPathComponent("Originals", isDirectory: true)
                try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: false)
                try Data("unknown Unicode leaf".utf8).write(
                    to: originals.appendingPathComponent("video-１２３４.mov")
                )
            }
            transaction = nil

            let events = ProjectPublicationTransaction.reconcile(in: base)

            XCTAssertTrue(events.contains(where: {
                if case .preserved(let url, _) = $0 { return url == envelope }
                return false
            }), "Expected preservation for \(hostileKind)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: envelope.path))
            XCTAssertEqual(try Data(contentsOf: outside), Data("never delete".utf8))
        }
    }

    func testConcurrentSameTitlePublicationsUseDistinctExclusiveLeaves() async throws {
        let base = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        var allPublished: [URL] = []
        for round in 0..<50 {
            let title = "Concurrent Project \(round)"
            let published = try await withThrowingTaskGroup(of: URL.self) { group in
                for index in 0..<2 {
                    group.addTask {
                        let id = UUID()
                        let transaction: ProjectPublicationTransaction
                        do {
                            transaction = try ProjectPublicationTransaction.begin(
                                in: base,
                                title: title,
                                projectID: id
                            )
                        } catch {
                            throw ConcurrentPublicationFailure(index: index, stage: "begin", error: error)
                        }
                        let metadata: ProjectMetadata
                        do {
                            metadata = try Self.makeInitialProject(
                                in: transaction.bundleURL,
                                id: id,
                                title: title,
                                videoBytes: Data("video-\(round)-\(index)".utf8)
                            )
                        } catch {
                            throw ConcurrentPublicationFailure(index: index, stage: "fixture", error: error)
                        }
                        do {
                            try transaction.validateAndSeal(expectedMetadata: metadata)
                            return try transaction.publish()
                        } catch {
                            throw ConcurrentPublicationFailure(index: index, stage: "seal/publish", error: error)
                        }
                    }
                }
                var urls: [URL] = []
                for try await url in group { urls.append(url) }
                return urls
            }
            XCTAssertEqual(Set(published.map(\.lastPathComponent)).count, 2)
            allPublished.append(contentsOf: published)
        }
        XCTAssertEqual(Set(allPublished.map(\.lastPathComponent)).count, 100)
        XCTAssertEqual(try visibleProjects(in: base).count, 100)
    }

    func testCandidateNamesRemainBoundedNormalizedAndDeterministic() {
        let base = URL(fileURLWithPath: "/private/tmp/projects", isDirectory: true)
        let titles = [
            String(repeating: "a", count: 255),
            String(repeating: "🏠", count: 100),
            ".Client/Exterior\\Final:\u{0007}\n Review",
            "",
            "...",
        ]
        for title in titles {
            let first = ProjectPublicationTransaction.candidateURL(in: base, title: title, attempt: 0)
            let again = ProjectPublicationTransaction.candidateURL(in: base, title: title, attempt: 0)
            XCTAssertEqual(first, again)
            XCTAssertLessThanOrEqual(first.lastPathComponent.utf8.count, 240)
            XCTAssertFalse(first.lastPathComponent.hasPrefix("."))
            XCTAssertEqual(first.pathExtension, "easysplatproj")
        }
        let composed = ProjectPublicationTransaction.candidateURL(
            in: base,
            title: "Caf\u{00E9} Exterior",
            attempt: 0
        )
        let decomposed = ProjectPublicationTransaction.candidateURL(
            in: base,
            title: "Cafe\u{0301} Exterior",
            attempt: 0
        )
        XCTAssertEqual(Data(composed.lastPathComponent.utf8), Data(decomposed.lastPathComponent.utf8))
    }

    func testFreshPublicationAttestationIsValidExactlyOnceForPublishedBundle() throws {
        let fixture = try makeAttestedPublicationFixture(title: "Attested Once")
        defer { try? FileManager.default.removeItem(at: fixture.base) }

        let metadata = try ProjectMetadataStore.load(
            from: ProjectPaths(root: fixture.publication.projectURL).metadataURL
        )
        XCTAssertNoThrow(try fixture.publication.attestation.consume(
            projectURL: fixture.publication.projectURL,
            metadata: metadata
        ))
        XCTAssertNoThrow(try fixture.publication.attestation.completeConsumption())
        XCTAssertThrowsError(try fixture.publication.attestation.consume(
            projectURL: fixture.publication.projectURL,
            metadata: metadata
        )) {
            XCTAssertEqual($0 as? FreshProjectPublicationAttestationError, .alreadyConsumed)
        }
    }

    func testFreshPublicationAttestationBurnsOnWrongURL() throws {
        let fixture = try makeAttestedPublicationFixture(title: "Wrong URL")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let metadata = try ProjectMetadataStore.load(
            from: ProjectPaths(root: fixture.publication.projectURL).metadataURL
        )
        let wrongURL = fixture.base.appendingPathComponent("Wrong.easysplatproj", isDirectory: true)

        XCTAssertThrowsError(try fixture.publication.attestation.consume(
            projectURL: wrongURL,
            metadata: metadata
        )) {
            XCTAssertEqual($0 as? FreshProjectPublicationAttestationError, .projectURLMismatch)
        }
        XCTAssertThrowsError(try fixture.publication.attestation.consume(
            projectURL: fixture.publication.projectURL,
            metadata: metadata
        )) {
            XCTAssertEqual($0 as? FreshProjectPublicationAttestationError, .alreadyConsumed)
        }
    }

    func testFreshPublicationAttestationRejectsMetadataBytesMutation() throws {
        let fixture = try makeAttestedPublicationFixture(title: "Metadata Drift")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let paths = ProjectPaths(root: fixture.publication.projectURL)
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        metadata.notes = "changed after publication"
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        XCTAssertThrowsError(try fixture.publication.attestation.consume(
            projectURL: fixture.publication.projectURL,
            metadata: metadata
        )) {
            XCTAssertEqual($0 as? FreshProjectPublicationAttestationError, .metadataChanged)
        }
    }

    func testFreshPublicationAttestationRejectsPresentedReceiptDrift() throws {
        let fixture = try makeAttestedPublicationFixture(title: "Receipt Drift")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let paths = ProjectPaths(root: fixture.publication.projectURL)
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertNotNil(metadata.videoInputReceipts)
        metadata.videoInputReceipts = nil

        XCTAssertThrowsError(try fixture.publication.attestation.consume(
            projectURL: fixture.publication.projectURL,
            metadata: metadata
        )) {
            XCTAssertEqual($0 as? FreshProjectPublicationAttestationError, .receiptChanged)
        }
    }

    func testFreshPublicationAttestationRejectsBundleRenameAndDirectoryRebind() throws {
        let fixture = try makeAttestedPublicationFixture(title: "Bundle Rebind")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let paths = ProjectPaths(root: fixture.publication.projectURL)
        let metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let displaced = fixture.base.appendingPathComponent("Displaced.easysplatproj", isDirectory: true)
        try FileManager.default.moveItem(at: fixture.publication.projectURL, to: displaced)
        try FileManager.default.createDirectory(
            at: fixture.publication.projectURL,
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(try fixture.publication.attestation.consume(
            projectURL: fixture.publication.projectURL,
            metadata: metadata
        )) {
            XCTAssertEqual($0 as? FreshProjectPublicationAttestationError, .projectIdentityChanged)
        }
    }

    func testDiscardedFreshPublicationAttestationCannotBeConsumed() throws {
        let fixture = try makeAttestedPublicationFixture(title: "Discarded")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let metadata = try ProjectMetadataStore.load(
            from: ProjectPaths(root: fixture.publication.projectURL).metadataURL
        )

        fixture.publication.attestation.discard()

        XCTAssertThrowsError(try fixture.publication.attestation.consume(
            projectURL: fixture.publication.projectURL,
            metadata: metadata
        )) {
            XCTAssertEqual($0 as? FreshProjectPublicationAttestationError, .discarded)
        }
    }

    func testPipelineStartupWithoutAttestationRunsVideoValidator() throws {
        let fixture = try makeAttestedPublicationFixture(title: "Legacy Validation")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        defer { fixture.publication.attestation.discard() }
        let paths = ProjectPaths(root: fixture.publication.projectURL)
        let metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let validatorCount = LockedInt()
        let runner = PipelineRunner(
            projectURL: fixture.publication.projectURL,
            config: .init(toolchain: TestToolchains.toolchainPaths(root: fixture.base)),
            tooling: .init(
                runner: MockSubprocessRunner(scripts: []),
                validateVideoInputs: { metadata, paths in
                    validatorCount.increment()
                    try VideoInputReceiptValidator.validateFiles(metadata: metadata, paths: paths)
                }
            )
        )

        try runner.authenticateStartupVideoInputs(
            metadata: metadata,
            paths: paths,
            freshPublicationAttestation: Optional<FreshProjectPublicationAttestation>.none
        )

        XCTAssertEqual(validatorCount.value, 1)
    }

    func testPipelineStartupAttestationSkipsOneValidatorAndStillPreparesRuntimeLease() throws {
        let fixture = try makeAttestedPublicationFixture(title: "Attested Startup")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let paths = ProjectPaths(root: fixture.publication.projectURL)
        let metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let validatorCount = LockedInt()
        let leaseCount = LockedInt()
        let runner = PipelineRunner(
            projectURL: fixture.publication.projectURL,
            config: .init(toolchain: TestToolchains.toolchainPaths(root: fixture.base)),
            tooling: .init(
                runner: MockSubprocessRunner(scripts: []),
                validateVideoInputs: { metadata, paths in
                    validatorCount.increment()
                    try VideoInputReceiptValidator.validateFiles(metadata: metadata, paths: paths)
                },
                prepareRuntimeInputLease: { metadata, paths, pairingPolicy in
                    leaseCount.increment()
                    return try RuntimeInputSnapshotLease.prepare(
                        metadata: metadata,
                        paths: paths,
                        pairingPolicy: pairingPolicy
                    )
                }
            )
        )

        try runner.authenticateStartupVideoInputs(
            metadata: metadata,
            paths: paths,
            freshPublicationAttestation: fixture.publication.attestation
        )
        let lease = try runner.prepareStartupRuntimeInputLease(
            metadata: metadata,
            paths: paths,
            pairingPolicy: metadata.resolvedRunPlan?.pairingPolicy,
            freshPublicationAttestation: fixture.publication.attestation
        )
        defer { lease.discard() }

        XCTAssertEqual(validatorCount.value, 0)
        XCTAssertEqual(leaseCount.value, 1)
        XCTAssertFalse(lease.videos.isEmpty)
    }

    func testFreshPublicationAttestationRejectsSameSizeWriteAndRestore() throws {
        let fixture = try makeAttestedPublicationFixture(title: "Write Restore")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let paths = ProjectPaths(root: fixture.publication.projectURL)
        let metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let video = try XCTUnwrap(metadata.videoInputReceipts?.first).projectRelativePath
        let videoURL = try paths.resolveProjectRelativePath(video)
        let original = try Data(contentsOf: videoURL)
        var changed = original
        changed[changed.startIndex] ^= 0xff
        try changed.write(to: videoURL)
        try original.write(to: videoURL)

        XCTAssertThrowsError(try fixture.publication.attestation.consume(
            projectURL: fixture.publication.projectURL,
            metadata: metadata
        )) {
            XCTAssertEqual($0 as? FreshProjectPublicationAttestationError, .filesystemChanged)
        }
    }

    func testFreshPublicationAttestationRejectsAttributeAndTimestampRestore() throws {
        let fixture = try makeAttestedPublicationFixture(title: "Attribute Restore")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let paths = ProjectPaths(root: fixture.publication.projectURL)
        let metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let video = try XCTUnwrap(metadata.videoInputReceipts?.first).projectRelativePath
        let videoURL = try paths.resolveProjectRelativePath(video)
        var before = stat()
        XCTAssertEqual(lstat(videoURL.path, &before), 0)
        XCTAssertEqual(chmod(videoURL.path, 0o400), 0)
        XCTAssertEqual(chmod(videoURL.path, mode_t(before.st_mode & 0o7777)), 0)
        var times = [before.st_atimespec, before.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, videoURL.path, &times, 0), 0)

        XCTAssertThrowsError(try fixture.publication.attestation.consume(
            projectURL: fixture.publication.projectURL,
            metadata: metadata
        )) {
            XCTAssertEqual($0 as? FreshProjectPublicationAttestationError, .filesystemChanged)
        }
    }

    func testFreshPublicationAttestationRejectsHardLinkChurn() throws {
        let fixture = try makeAttestedPublicationFixture(title: "Link Churn")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let paths = ProjectPaths(root: fixture.publication.projectURL)
        let metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let video = try XCTUnwrap(metadata.videoInputReceipts?.first).projectRelativePath
        let videoURL = try paths.resolveProjectRelativePath(video)
        let alias = fixture.base.appendingPathComponent("linked-video")
        XCTAssertEqual(link(videoURL.path, alias.path), 0)
        XCTAssertEqual(unlink(alias.path), 0)

        XCTAssertThrowsError(try fixture.publication.attestation.consume(
            projectURL: fixture.publication.projectURL,
            metadata: metadata
        )) {
            XCTAssertEqual($0 as? FreshProjectPublicationAttestationError, .filesystemChanged)
        }
    }

    func testFreshPublicationAttestationRejectsRenameAwayAndRestore() throws {
        let fixture = try makeAttestedPublicationFixture(title: "Rename Restore")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let paths = ProjectPaths(root: fixture.publication.projectURL)
        let metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let video = try XCTUnwrap(metadata.videoInputReceipts?.first).projectRelativePath
        let videoURL = try paths.resolveProjectRelativePath(video)
        let moved = videoURL.deletingLastPathComponent().appendingPathComponent("moved-video")
        try FileManager.default.moveItem(at: videoURL, to: moved)
        try FileManager.default.moveItem(at: moved, to: videoURL)

        XCTAssertThrowsError(try fixture.publication.attestation.consume(
            projectURL: fixture.publication.projectURL,
            metadata: metadata
        )) {
            XCTAssertEqual($0 as? FreshProjectPublicationAttestationError, .filesystemChanged)
        }
    }

    func testFreshPublicationAttestationRejectsUnexpectedTreeEntryAndLibraryMutation() throws {
        for mutation in ["tree", "library"] {
            let fixture = try makeAttestedPublicationFixture(title: "Unexpected \(mutation)")
            defer { try? FileManager.default.removeItem(at: fixture.base) }
            let paths = ProjectPaths(root: fixture.publication.projectURL)
            let metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
            let unexpected = mutation == "tree"
                ? fixture.publication.projectURL.appendingPathComponent("unexpected")
                : fixture.base.appendingPathComponent("library-churn")
            try Data("unexpected".utf8).write(to: unexpected)
            try FileManager.default.removeItem(at: unexpected)

            XCTAssertThrowsError(try fixture.publication.attestation.consume(
                projectURL: fixture.publication.projectURL,
                metadata: metadata
            ), mutation) {
                XCTAssertEqual($0 as? FreshProjectPublicationAttestationError, .filesystemChanged)
            }
        }
    }

    func testFreshPublicationAttestationRejectsMutationBetweenConsumeAndCompletion() throws {
        let fixture = try makeAttestedPublicationFixture(title: "Mid Consumption")
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let paths = ProjectPaths(root: fixture.publication.projectURL)
        let metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let video = try XCTUnwrap(metadata.videoInputReceipts?.first).projectRelativePath
        let videoURL = try paths.resolveProjectRelativePath(video)
        let original = try Data(contentsOf: videoURL)

        try fixture.publication.attestation.consume(
            projectURL: fixture.publication.projectURL,
            metadata: metadata
        )
        try Data(repeating: 0x5a, count: original.count).write(to: videoURL)
        try original.write(to: videoURL)

        XCTAssertThrowsError(try fixture.publication.attestation.completeConsumption()) {
            XCTAssertEqual($0 as? FreshProjectPublicationAttestationError, .filesystemChanged)
        }
    }

    func testFreshPublicationVideoHandoffIsConsumedOnceAcrossTitleCollisionRetry() throws {
        let base = temporaryDirectory(suffix: "fresh-handoff-collision")
        defer { try? FileManager.default.removeItem(at: base) }
        let title = "Occupied Title"
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let occupied = ProjectPublicationTransaction.candidateURL(
            in: base,
            title: title,
            attempt: 0
        )
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
        let id = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: title,
            projectID: id
        )
        let metadata = try Self.makeInitialProject(
            in: transaction.bundleURL,
            id: id,
            title: title
        )
        try transaction.validateAndSeal(expectedMetadata: metadata)
        let consumeCount = LockedInt()

        let publication = try transaction.publishWithFreshAttestationForTesting(
            consumeVideoIntegrityHandoff: {
            consumeCount.increment()
            }
        )
        defer { publication.attestation.discard() }

        XCTAssertEqual(consumeCount.value, 1)
        XCTAssertEqual(
            publication.projectURL.lastPathComponent,
            ProjectPublicationTransaction.candidateURL(
                in: base,
                title: title,
                attempt: 1
            ).lastPathComponent
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: occupied.path))
    }

    func testFreshPublicationRejectsRenameAwayAndRestoreDuringVideoHandoff() throws {
        let base = temporaryDirectory(suffix: "fresh-handoff-mutation")
        defer { try? FileManager.default.removeItem(at: base) }
        let title = "Handoff Mutation"
        let id = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: title,
            projectID: id
        )
        let metadata = try Self.makeInitialProject(
            in: transaction.bundleURL,
            id: id,
            title: title
        )
        try transaction.validateAndSeal(expectedMetadata: metadata)
        let paths = ProjectPaths(root: transaction.bundleURL)
        let relativeVideo = try XCTUnwrap(metadata.videoInputReceipts?.first?.projectRelativePath)
        let videoURL = try paths.resolveProjectRelativePath(relativeVideo)
        let displaced = videoURL.deletingLastPathComponent().appendingPathComponent("displaced-video")

        XCTAssertThrowsError(try transaction.publishWithFreshAttestationForTesting(
            consumeVideoIntegrityHandoff: {
            try FileManager.default.moveItem(at: videoURL, to: displaced)
            try FileManager.default.moveItem(at: displaced, to: videoURL)
            }
        )) {
            XCTAssertEqual($0 as? FreshProjectPublicationAttestationError, .filesystemChanged)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ProjectPublicationTransaction.candidateURL(
                in: base,
                title: title,
                attempt: 0
            ).path
        ))
        XCTAssertThrowsError(try transaction.abort())
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.envelopeURL.path))
    }

    func testFreshPublicationCancellationDuringVideoHandoffLeavesBundleHidden() throws {
        let base = temporaryDirectory(suffix: "fresh-handoff-cancellation")
        defer { try? FileManager.default.removeItem(at: base) }
        let title = "Cancelled Handoff"
        let id = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: title,
            projectID: id
        )
        let metadata = try Self.makeInitialProject(
            in: transaction.bundleURL,
            id: id,
            title: title
        )
        try transaction.validateAndSeal(expectedMetadata: metadata)

        XCTAssertThrowsError(try transaction.publishWithFreshAttestationForTesting(
            consumeVideoIntegrityHandoff: {
            throw CancellationError()
            }
        )) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: ProjectPublicationTransaction.candidateURL(
                in: base,
                title: title,
                attempt: 0
            ).path
        ))
        XCTAssertNoThrow(try transaction.abort())
    }

    func testFreshPublicationAttestationFailureRollsVisibleBundleBackBeforeCleanup() throws {
        let base = temporaryDirectory(suffix: "fresh-attestation-rollback")
        defer { try? FileManager.default.removeItem(at: base) }
        let title = "Attestation Rollback"
        let id = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: title,
            projectID: id
        )
        let metadata = try Self.makeInitialProject(
            in: transaction.bundleURL,
            id: id,
            title: title
        )
        try transaction.validateAndSeal(expectedMetadata: metadata)
        let relativeVideo = try XCTUnwrap(metadata.videoInputReceipts?.first?.projectRelativePath)
        let visibleURL = ProjectPublicationTransaction.candidateURL(
            in: base,
            title: title,
            attempt: 0
        )

        XCTAssertThrowsError(try transaction.publishWithFreshAttestationForTesting(
            beforePublicationAttestation: {
                let visiblePaths = ProjectPaths(root: visibleURL)
                let videoURL = try visiblePaths.resolveProjectRelativePath(relativeVideo)
                let displaced = videoURL.deletingLastPathComponent()
                    .appendingPathComponent("displaced-at-attestation")
                try FileManager.default.moveItem(at: videoURL, to: displaced)
                try FileManager.default.moveItem(at: displaced, to: videoURL)
            }
        )) {
            XCTAssertEqual($0 as? FreshProjectPublicationAttestationError, .filesystemChanged)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: visibleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.bundleURL.path))
    }

    private func makeAttestedPublicationFixture(
        title: String
    ) throws -> (base: URL, publication: FreshProjectPublication) {
        let base = temporaryDirectory(suffix: "fresh-attestation")
        let id = UUID()
        let transaction = try ProjectPublicationTransaction.begin(
            in: base,
            title: title,
            projectID: id
        )
        let metadata = try Self.makeInitialProject(
            in: transaction.bundleURL,
            id: id,
            title: title
        )
        try transaction.validateAndSeal(expectedMetadata: metadata)
        return (base, try transaction.publishWithFreshAttestationForTesting())
    }

    private static func makeInitialProject(
        in root: URL,
        id: UUID,
        title: String,
        notes: String? = nil,
        videoBytes: Data = Data("video-fixture".utf8)
    ) throws -> ProjectMetadata {
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let relativeVideo = "Originals/video-0000.mov"
        let input = InputSpec.video(files: [relativeVideo])
        let options = RequestedRunOptions()
        let plan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        let sourceSHA256 = SHA256.hash(data: videoBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let clipIdentity = try XCTUnwrap(VideoClipIdentityResolver.resolve(
            sourceSHA256s: [sourceSHA256],
            pairingPolicy: plan.pairingPolicy
        ).first)
        let (_, receipt) = try TestFileBuilder.writeControlledVideoReceipt(
            paths: paths,
            bytes: videoBytes,
            analysisPolicy: VideoFrameAnalysisPolicy(resolvedRunPlan: plan),
            clipGroupID: clipIdentity.groupID
        )
        let metadata = ProjectMetadata(
            id: id,
            title: title,
            input: input,
            videoInputReceipts: [receipt],
            requestedRunOptions: options,
            resolvedRunPlan: plan,
            lastRunStartedAt: Date(),
            notes: notes
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        return metadata
    }

    private static func makeEmptyMixedInitialProject(
        in root: URL,
        id: UUID,
        title: String,
        videoBytes: Data = Data("mixed-video-fixture".utf8)
    ) throws -> ProjectMetadata {
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        if !FileManager.default.fileExists(atPath: paths.importedPhotosURL.path) {
            try FileManager.default.createDirectory(
                at: paths.importedPhotosURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let relativeVideo = "Originals/video-0000.mov"
        let input = InputSpec.mixed(
            videos: [relativeVideo],
            photosFolder: "Originals/Photos"
        )
        let options = RequestedRunOptions()
        let plan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        let sourceSHA256 = sha256(videoBytes)
        let clipIdentity = try XCTUnwrap(VideoClipIdentityResolver.resolve(
            sourceSHA256s: [sourceSHA256],
            pairingPolicy: plan.pairingPolicy
        ).first)
        let (_, receipt) = try TestFileBuilder.writeControlledVideoReceipt(
            paths: paths,
            bytes: videoBytes,
            analysisPolicy: VideoFrameAnalysisPolicy(resolvedRunPlan: plan),
            clipGroupID: clipIdentity.groupID
        )
        let metadata = ProjectMetadata(
            id: id,
            title: title,
            input: input,
            videoInputReceipts: [receipt],
            photoInputReceipts: [],
            photoSelectionReceipt: nil,
            requestedRunOptions: options,
            resolvedRunPlan: plan,
            lastRunStartedAt: Date()
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        return metadata
    }

    private static func writeUncheckedMetadata(
        _ metadata: ProjectMetadata,
        to url: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(to: url, options: .atomic)
    }

    private static func selectionReceipt(
        replacing receipt: PhotoSelectionReceipt,
        projectRelativePath: String? = nil,
        byteCount: Int64,
        sha256: String
    ) -> PhotoSelectionReceipt {
        PhotoSelectionReceipt(
            schemaVersion: receipt.schemaVersion,
            projectRelativePath: projectRelativePath ?? receipt.projectRelativePath,
            byteCount: byteCount,
            sha256: sha256,
            artifactSchemaVersion: receipt.artifactSchemaVersion,
            analysisRecipeVersion: receipt.analysisRecipeVersion,
            analysisRecipeSHA256: receipt.analysisRecipeSHA256,
            selectorPolicyVersion: receipt.selectorPolicyVersion,
            selectorPolicySHA256: receipt.selectorPolicySHA256
        )
    }

    private static func photoReceipt(
        replacing receipt: PhotoInputReceipt,
        sourceSHA256: String,
        retainedRank: Int
    ) -> PhotoInputReceipt {
        PhotoInputReceipt(
            schemaVersion: receipt.schemaVersion,
            projectRelativePath: receipt.projectRelativePath,
            safeDisplayName: receipt.safeDisplayName,
            byteCount: receipt.byteCount,
            sha256: receipt.sha256,
            pixelWidth: receipt.pixelWidth,
            pixelHeight: receipt.pixelHeight,
            orientation: receipt.orientation,
            typeIdentifier: receipt.typeIdentifier,
            source: PhotoSourceProvenance(
                byteCount: receipt.source.byteCount,
                sha256: sourceSHA256,
                typeIdentifier: receipt.source.typeIdentifier
            ),
            importMode: receipt.importMode,
            analysisEvidence: receipt.analysisEvidence,
            retainedRank: retainedRank
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func prepareMixedInputs(
        in root: URL,
        id: UUID,
        title: String,
        checkpoint: (ProjectPublicationTransaction.Checkpoint) throws -> Void
    ) throws -> ProjectMetadata {
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let videoRelative = "Originals/video-0000.mov"
        let videoBytes = Data("child-video".utf8)
        let photoRelative = "Originals/Photos/photo-0000.jpg"
        let input = InputSpec.mixed(
            videos: [videoRelative],
            photosFolder: "Originals/Photos"
        )
        let options = RequestedRunOptions()
        let plan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        let sourceSHA256 = SHA256.hash(data: videoBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        let clipIdentity = try XCTUnwrap(VideoClipIdentityResolver.resolve(
            sourceSHA256s: [sourceSHA256],
            pairingPolicy: plan.pairingPolicy
        ).first)
        let (_, videoReceipt) = try TestFileBuilder.writeControlledVideoReceipt(
            paths: paths,
            bytes: videoBytes,
            analysisPolicy: VideoFrameAnalysisPolicy(resolvedRunPlan: plan),
            clipGroupID: clipIdentity.groupID
        )
        try checkpoint(.videoAdopted)

        let photo = root.appendingPathComponent(photoRelative)
        let photoBytes = Data("child-photo".utf8)
        try FileManager.default.createDirectory(
            at: photo.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try photoBytes.write(to: photo)
        guard chmod(photo.path, S_IRUSR | S_IWUSR) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        let photoSHA256 = try GeometryArtifactStore.sha256(of: photo)
        let analysisEvidence = TestFileBuilder.photoAnalysisEvidence(
            sourceSHA256: photoSHA256
        )
        let photoReceipt = PhotoInputReceipt(
            projectRelativePath: photoRelative,
            safeDisplayName: "Capture.jpg",
            byteCount: Int64(photoBytes.count),
            sha256: photoSHA256,
            pixelWidth: 16,
            pixelHeight: 16,
            orientation: 1,
            typeIdentifier: "public.jpeg",
            analysisEvidence: analysisEvidence,
            retainedRank: 0
        )
        let selectionArtifact = PhotoSelectionArtifact(
            strategy: .visualDiversity,
            analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
            analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256,
            selectorPolicyVersion: PhotoDiversitySelector.selectorPolicyVersion,
            selectorPolicySHA256: PhotoDiversitySelector.selectorPolicySHA256,
            inputOrdering: plan.inputOrdering,
            requestedPhotoSelection: plan.photoSelection,
            admissionCapacity: 1,
            discoveredCount: 1,
            acceptedCount: 1,
            unreadableCount: 0,
            exactDuplicateCount: 0,
            companionDuplicateCount: 0,
            candidates: [PhotoSelectionCandidateArtifact(
                admissionOrdinal: 0,
                evidence: analysisEvidence,
                retainedRank: 0
            )],
            retainedSourceSHA256s: [photoSHA256],
            canonicalRetainedSourceSHA256s: [photoSHA256]
        )
        let selectionEvidence = try PhotoSelectionArtifactStore.save(
            selectionArtifact,
            to: paths.photoSelectionArtifactURL,
            projectPaths: paths
        )
        try checkpoint(.photosAdopted)
        let selectionReceipt = PhotoSelectionReceipt(
            projectRelativePath: PhotoSelectionReceipt.projectRelativePath,
            byteCount: selectionEvidence.byteCount,
            sha256: selectionEvidence.sha256,
            artifactSchemaVersion: selectionArtifact.schemaVersion,
            analysisRecipeVersion: selectionArtifact.analysisRecipeVersion,
            analysisRecipeSHA256: selectionArtifact.analysisRecipeSHA256,
            selectorPolicyVersion: selectionArtifact.selectorPolicyVersion,
            selectorPolicySHA256: selectionArtifact.selectorPolicySHA256
        )
        let metadata = ProjectMetadata(
            id: id,
            title: title,
            input: input,
            videoInputReceipts: [videoReceipt],
            photoInputReceipts: [photoReceipt],
            photoSelectionReceipt: selectionReceipt,
            requestedRunOptions: options,
            resolvedRunPlan: plan,
            lastRunStartedAt: Date(),
            notes: "Child crash fixture"
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        try PhotoInputReceiptValidator.validateMetadata(metadata, paths: paths)
        _ = try PhotoSelectionProjection.loadVerified(metadata: metadata, paths: paths)
        return metadata
    }

    private func runCrashHelper(
        mode: String,
        base: URL,
        checkpoint: ProjectPublicationTransaction.Checkpoint,
        projectID: UUID = UUID()
    ) throws -> Process {
        try runHelper(environment: [
            "EASYSPLAT_PUBLICATION_HELPER_MODE": mode,
            "EASYSPLAT_PUBLICATION_HELPER_BASE": base.path,
            "EASYSPLAT_PUBLICATION_HELPER_CHECKPOINT": checkpoint.rawValue,
            "EASYSPLAT_PUBLICATION_HELPER_PROJECT_ID": projectID.uuidString,
        ])
    }

    private func runReconcileHelper(base: URL, marker: URL) throws -> Process {
        try runHelper(environment: [
            "EASYSPLAT_PUBLICATION_HELPER_MODE": "reconcile",
            "EASYSPLAT_PUBLICATION_HELPER_BASE": base.path,
            "EASYSPLAT_PUBLICATION_HELPER_MARKER": marker.path,
        ])
    }

    private func runHelper(environment additions: [String: String]) throws -> Process {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            "EasySplatCoreTests.ProjectPublicationTransactionTests/testProjectPublicationCrashHelperEntryPoint",
            Bundle(for: ProjectPublicationTransactionTests.self).bundleURL.path,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging(additions) { _, new in new }
        process.standardOutput = output
        process.standardError = output
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        try process.run()
        output.fileHandleForWriting.closeFile()
        if terminated.wait(timeout: .now() + 20) == .timedOut {
            process.terminate()
            _ = terminated.wait(timeout: .now() + 5)
            let diagnostics = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "<non-UTF-8 child output>"
            throw NSError(
                domain: "ProjectPublicationTransactionTests.ChildTimeout",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: diagnostics]
            )
        }
        return process
    }

    private func makeExistingVisibleSentinel(
        in base: URL
    ) throws -> (bundle: URL, sentinel: URL) {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let bundle = base.appendingPathComponent("Existing.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
        let sentinel = bundle.appendingPathComponent("sentinel")
        try Data("existing".utf8).write(to: sentinel)
        return (bundle, sentinel)
    }

    private func addUnknownTransactionRootEntry(
        in base: URL,
        suffix: String
    ) throws -> URL {
        let container = base.appendingPathComponent(
            ProjectPublicationTransaction.containerName,
            isDirectory: true
        )
        let unknown = container.appendingPathComponent("unknown-\(suffix)")
        try Data("unknown".utf8).write(to: unknown)
        return unknown
    }

    private static func makeManyVideoProject(
        in root: URL,
        id: UUID,
        title: String,
        count: Int
    ) throws -> ProjectMetadata {
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        var files: [String] = []
        var payloads: [Data] = []
        var digests: [String] = []
        for index in 0..<count {
            let relative = String(format: "Originals/video-%04d.mov", index)
            let bytes = Data("video-fixture-\(index)".utf8)
            files.append(relative)
            payloads.append(bytes)
            digests.append(SHA256.hash(data: bytes)
                .map { String(format: "%02x", $0) }
                .joined())
        }
        let input = InputSpec.video(files: files)
        let options = RequestedRunOptions()
        let plan = RunPlanResolver.resolve(
            requestedOptions: options,
            input: input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        let identities = try VideoClipIdentityResolver.resolve(
            sourceSHA256s: digests,
            pairingPolicy: plan.pairingPolicy
        )
        let groupIDs = Dictionary(
            uniqueKeysWithValues: identities.map { ($0.sourceIndex, $0.groupID) }
        )
        var receipts: [VideoInputReceipt] = []
        for index in 0..<count {
            let (_, receipt) = try TestFileBuilder.writeControlledVideoReceipt(
                paths: paths,
                index: index,
                bytes: payloads[index],
                safeDisplayName: "Capture \(index + 1).mov",
                analysisPolicy: VideoFrameAnalysisPolicy(resolvedRunPlan: plan),
                clipGroupID: groupIDs[index]
            )
            receipts.append(receipt)
        }
        let metadata = ProjectMetadata(
            id: id,
            title: title,
            input: input,
            videoInputReceipts: receipts,
            requestedRunOptions: options,
            resolvedRunPlan: plan,
            lastRunStartedAt: Date()
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        return metadata
    }

    private func temporaryDirectory(suffix: String = "") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "EasySplatProjectPublicationTests-\(UUID().uuidString)-\(suffix)",
            isDirectory: true
        )
    }

    private func visibleProjects(in base: URL) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: base.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { $0.pathExtension == "easysplatproj" }
    }

    private func transactionEnvelopes(in base: URL) throws -> [URL] {
        let container = base.appendingPathComponent(
            ProjectPublicationTransaction.containerName,
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: container.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: container,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix("txn-")
                || $0.lastPathComponent.hasPrefix(".deleting-")
        }
    }

    private func transactionContainerLeaves(in base: URL) throws -> [String] {
        let container = base.appendingPathComponent(
            ProjectPublicationTransaction.containerName,
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: container.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: container.path)
    }

    private func permissions(at url: URL) throws -> mode_t {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return status.st_mode & mode_t(0o7777)
    }

    private func identity(at url: URL) throws -> TestIdentity {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return TestIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }
}

private struct InjectedCrash: Error {}

private struct ConcurrentPublicationFailure: Error, CustomStringConvertible {
    let index: Int
    let stage: String
    let message: String

    init(index: Int, stage: String, error: Error) {
        self.index = index
        self.stage = stage
        message = String(describing: error)
    }

    var description: String { "publication \(index) failed during \(stage): \(message)" }
}

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class LockedURLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: URL?

    var value: URL? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class LockedTestIdentityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: TestIdentity?

    var value: TestIdentity? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class LockedCheckpointList: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProjectPublicationTransaction.Checkpoint] = []

    var value: [ProjectPublicationTransaction.Checkpoint] {
        lock.withLock { storage }
    }

    func append(_ checkpoint: ProjectPublicationTransaction.Checkpoint) {
        lock.withLock { storage.append(checkpoint) }
    }
}

private struct TestIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
}

private enum HostileKind: String, CaseIterable {
    case unknown
    case framesFile
    case symlink
    case hardlink
    case fifo
    case unicodeDigits
}
#endif
