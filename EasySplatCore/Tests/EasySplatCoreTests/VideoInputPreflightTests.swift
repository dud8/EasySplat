import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import EasySplatCore

final class VideoInputPreflightTests: XCTestCase {
    func testProjectAdoptionPersistsReusableAnalysisBoundToResolvedPolicy() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("capture.mov")
        try Data("synthetic-video-payload".utf8).write(to: source)
        let policy = VideoFrameAnalysisPolicy(
            targetFrameCeiling: 250,
            targetFPS: 3,
            maximumConcurrentDecoders: 1
        )
        let analyzedOptions = FrameExtractionOptionsRecorder()
        let preflight = VideoInputPreflight(
            limits: .init(
                maximumVideoCount: 4,
                maximumTotalBytes: 1_024 * 1_024,
                minimumFreeSpaceReserveBytes: 0,
                maximumConcurrentDecoders: 2
            ),
            availableCapacity: { _ in 1_024 * 1_024 },
            analyze: { _, options in
                analyzedOptions.record(options)
                return .fixture
            }
        )
        let prepared = try await preflight.prepare(
            videoURLs: [source],
            stagingParent: library,
            requiredAtomicWorkspaceReserveBytes: 0,
            analysisPolicy: policy,
            pairingPolicy: .orderedContinuous,
            progress: { _, _ in }
        )
        defer { prepared.discard() }
        let project = library.appendingPathComponent("Result.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let paths = ProjectPaths(root: project)
        var adoption = ProjectInputAdoption(
            requestedInput: .video(files: [source.path])
        )

        try adoption.adoptVideos(prepared, into: paths)
        let integrityHandoff = try XCTUnwrap(adoption.videoInputIntegrityHandoff)
        defer { integrityHandoff.discard() }

        let receipt = try XCTUnwrap(adoption.videoInputReceipts?.first)
        XCTAssertEqual(analyzedOptions.value?.targetCount, 250)
        XCTAssertEqual(analyzedOptions.value?.targetFPS, 3)
        XCTAssertEqual(receipt.analysisPolicySHA256, policy.sha256)
        XCTAssertNoThrow(try VideoInputReceiptValidator.validateFiles(
            metadata: ProjectMetadata(
                title: "Adopted",
                input: adoption.input,
                videoInputReceipts: [receipt]
            ),
            paths: paths
        ))
        let artifact = try VideoFrameAnalysisArtifactStore.load(
            from: try paths.resolveProjectRelativePath(receipt.analysisArtifactPath),
            receipt: receipt,
            expectedPolicy: policy,
            expectedClipGroupID: "video_000",
            expectedSourceIndex: 0,
            projectPaths: paths
        )
        XCTAssertEqual(artifact.candidates.count, 3)
        XCTAssertEqual(artifact.decodedFrameCount, 3)
    }

    func testPhotoOnlyProjectAdoptionHasNoVideoIntegrityHandoff() {
        let adoption = ProjectInputAdoption(
            requestedInput: .photos(folder: "/tmp/photo-input")
        )

        XCTAssertNil(adoption.videoInputIntegrityHandoff)
    }

    func testPrepareSnapshotsVideoWithPrivateModesAndAdoptsWithoutSource() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("walk\nthrough.MOV")
        let bytes = Data("synthetic-video-payload".utf8)
        try bytes.write(to: source)
        let observedURLs = URLRecorder()
        let preflight = VideoInputPreflight(
            limits: .init(
                maximumVideoCount: 4,
                maximumTotalBytes: 1_024 * 1_024,
                minimumFreeSpaceReserveBytes: 0,
                maximumConcurrentDecoders: 2
            ),
            availableCapacity: { _ in 1_024 * 1_024 },
            analyze: { url, _ in
                observedURLs.append(url)
                return VideoInputAnalysisEvidence(
                    trackID: 1,
                    pixelWidth: 64,
                    pixelHeight: 48,
                    durationSeconds: 1,
                    nominalFrameRate: 30,
                    isHDR: false,
                    decodedFrameCount: 3,
                    preferredTransform: .identity
                )
            }
        )

        let prepared = try await preflight.prepare(
            videoURLs: [source],
            stagingParent: library,
            requiredAtomicWorkspaceReserveBytes: 0,
            progress: { _, _ in }
        )
        defer { prepared.discard() }

        XCTAssertEqual(prepared.videos.count, 1)
        let staged = try XCTUnwrap(prepared.videos.first)
        XCTAssertEqual(staged.safeDisplayName, "walk through.MOV")
        XCTAssertEqual(staged.stagedURL.lastPathComponent, "video-0000.mov")
        XCTAssertEqual(staged.byteCount, Int64(bytes.count))
        XCTAssertEqual(staged.sha256, SHA256.hash(data: bytes).hexString)
        XCTAssertEqual(try posixMode(of: prepared.stagingRoot), 0o700)
        XCTAssertEqual(try posixMode(of: staged.stagedURL), 0o600)
        XCTAssertEqual(observedURLs.values, [staged.stagedURL])

        try FileManager.default.removeItem(at: source)
        let project = library.appendingPathComponent("Result.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let adopted = try prepared.adopt(
            into: ProjectPaths(root: project).originalsURL
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.stagingRoot.path))
        XCTAssertEqual(adopted.count, 1)
        XCTAssertEqual(adopted[0].stagedURL.lastPathComponent, "video-0000.mov")
        XCTAssertEqual(try Data(contentsOf: adopted[0].stagedURL), bytes)
        XCTAssertEqual(try posixMode(of: adopted[0].stagedURL), 0o600)
        XCTAssertEqual(try prepared.adopt(into: ProjectPaths(root: project).originalsURL), adopted)
    }

    func testAdoptNeverReplacesDestinationCreatedAfterPrecheck() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("capture.mov")
        try Data("source".utf8).write(to: source)
        let prepared = try await makePreflight(capacity: { 1_000_000 }).prepare(
            videoURLs: [source],
            stagingParent: library,
            requiredAtomicWorkspaceReserveBytes: 0,
            progress: { _, _ in }
        )
        defer { prepared.discard() }
        let project = library.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let destination = ProjectPaths(root: project).originalsURL
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let sentinel = destination.appendingPathComponent("sentinel")
        try Data("existing".utf8).write(to: sentinel)

        XCTAssertThrowsError(try prepared.adopt(into: destination))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("existing".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.stagingRoot.path))
    }

    func testAdoptCanRetryAfterDestinationRaceClosesRootWatch() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("capture.mov")
        let bytes = Data("retryable-video".utf8)
        try bytes.write(to: source)
        let race = AdoptionDestinationRace()
        let prepared = try await makePreflight(capacity: race.availableCapacity).prepare(
            videoURLs: [source],
            stagingParent: library,
            requiredAtomicWorkspaceReserveBytes: 0,
            progress: { _, _ in }
        )
        defer { prepared.discard() }
        let project = library.appendingPathComponent("Retry.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let originals = ProjectPaths(root: project).originalsURL
        race.arm(destination: originals)

        XCTAssertThrowsError(try prepared.adopt(into: originals))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.stagingRoot.path))
        try FileManager.default.removeItem(at: originals)

        let adopted = try prepared.adopt(into: originals)
        XCTAssertEqual(try Data(contentsOf: adopted[0].stagedURL), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.stagingRoot.path))
    }

    func testIntegrityHandoffIsOneShotAfterSuccessorWatchesAreArmed() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("capture.mov")
        try Data("handoff-video".utf8).write(to: source)
        let prepared = try await makePreflight(capacity: { 1_000_000 }).prepare(
            videoURLs: [source],
            stagingParent: library,
            requiredAtomicWorkspaceReserveBytes: 0,
            progress: { _, _ in }
        )
        let project = library.appendingPathComponent("Handoff.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        _ = try prepared.adopt(into: ProjectPaths(root: project).originalsURL)

        let handoff = try prepared.takeIntegrityHandoff()
        XCTAssertThrowsError(try prepared.takeIntegrityHandoff()) { error in
            XCTAssertEqual(error as? VideoInputIntegrityHandoffError, .alreadyIssued)
        }
        XCTAssertNoThrow(try handoff.consumeAfterSuccessorArmed())
        XCTAssertThrowsError(try handoff.consumeAfterSuccessorArmed()) { error in
            XCTAssertEqual(error as? VideoInputIntegrityHandoffError, .alreadyConsumed)
        }
    }

    func testIntegrityHandoffRejectsMutationAfterAdoption() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("capture.mov")
        try Data("handoff-video".utf8).write(to: source)
        let prepared = try await makePreflight(capacity: { 1_000_000 }).prepare(
            videoURLs: [source],
            stagingParent: library,
            requiredAtomicWorkspaceReserveBytes: 0,
            progress: { _, _ in }
        )
        let project = library.appendingPathComponent("Changed.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let adopted = try prepared.adopt(into: ProjectPaths(root: project).originalsURL)
        let handoff = try prepared.takeIntegrityHandoff()
        try Data("changed-video".utf8).write(to: adopted[0].stagedURL)

        XCTAssertThrowsError(try handoff.consumeAfterSuccessorArmed()) { error in
            XCTAssertEqual(error as? VideoInputIntegrityHandoffError, .filesystemChanged)
        }
    }

    func testIntegrityHandoffRejectsRenameAwayAndRestoreAfterAdoption() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("capture.mov")
        try Data("handoff-video".utf8).write(to: source)
        let prepared = try await makePreflight(capacity: { 1_000_000 }).prepare(
            videoURLs: [source],
            stagingParent: library,
            requiredAtomicWorkspaceReserveBytes: 0,
            progress: { _, _ in }
        )
        let project = library.appendingPathComponent("Renamed.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let adopted = try prepared.adopt(into: ProjectPaths(root: project).originalsURL)
        let handoff = try prepared.takeIntegrityHandoff()
        let moved = adopted[0].stagedURL.deletingLastPathComponent()
            .appendingPathComponent("moved.mov")
        try FileManager.default.moveItem(at: adopted[0].stagedURL, to: moved)
        try FileManager.default.moveItem(at: moved, to: adopted[0].stagedURL)

        XCTAssertThrowsError(try handoff.consumeAfterSuccessorArmed()) { error in
            XCTAssertEqual(error as? VideoInputIntegrityHandoffError, .filesystemChanged)
        }
    }

    func testDiscardedIntegrityHandoffCannotBeConsumed() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("capture.mov")
        try Data("handoff-video".utf8).write(to: source)
        let prepared = try await makePreflight(capacity: { 1_000_000 }).prepare(
            videoURLs: [source],
            stagingParent: library,
            requiredAtomicWorkspaceReserveBytes: 0,
            progress: { _, _ in }
        )
        let project = library.appendingPathComponent("Discarded.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        _ = try prepared.adopt(into: ProjectPaths(root: project).originalsURL)
        let handoff = try prepared.takeIntegrityHandoff()

        handoff.discard()
        XCTAssertThrowsError(try handoff.consumeAfterSuccessorArmed()) { error in
            XCTAssertEqual(error as? VideoInputIntegrityHandoffError, .discarded)
        }
    }

    func testCapacityProofUsesLowerValueAndFailsClosed() throws {
        XCTAssertEqual(
            try VideoInputPreflight.provenAvailableCapacity(ordinary: 100, important: 200),
            100
        )
        XCTAssertEqual(
            try VideoInputPreflight.provenAvailableCapacity(ordinary: 200, important: 100),
            100
        )
        XCTAssertEqual(
            try VideoInputPreflight.provenAvailableCapacity(
                ordinary: Int64.max,
                important: Int64.max
            ),
            Int64.max
        )
        for values: (Int64?, Int64?) in [
            (nil, 100),
            (100, nil),
            (-1, 100),
            (100, -1),
        ] {
            XCTAssertThrowsError(
                try VideoInputPreflight.provenAvailableCapacity(
                    ordinary: values.0,
                    important: values.1
                )
            ) { error in
                XCTAssertEqual(error as? VideoInputCapacityEvidenceError, .unavailable)
            }
        }
    }

    func testCapacityBoundariesIncludeSourceBytesAndRecheckOnlyReserveAtAdoption() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("capture.mov")
        let bytes = Data(repeating: 0x5a, count: 16)
        try bytes.write(to: source)

        let below = CapacitySequence([35])
        let belowPreflight = makePreflight(capacity: { try below.next() })
        do {
            _ = try await belowPreflight.prepare(
                videoURLs: [source],
                stagingParent: library,
                requiredAtomicWorkspaceReserveBytes: 20,
                progress: { _, _ in }
            )
            XCTFail("Source bytes plus reserve must fit before staging")
        } catch let failure as VideoInputPreflightFailure {
            XCTAssertEqual(
                failure.rejectedVideos.first?.issue,
                .insufficientSpace(required: 36, available: 35)
            )
        }

        let exact = CapacitySequence([36, 20])
        let exactPreflight = makePreflight(capacity: { try exact.next() })
        let prepared = try await exactPreflight.prepare(
            videoURLs: [source],
            stagingParent: library,
            requiredAtomicWorkspaceReserveBytes: 20,
            progress: { _, _ in }
        )
        let project = library.appendingPathComponent("Exact.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        XCTAssertEqual(try prepared.adopt(into: ProjectPaths(root: project).originalsURL).count, 1)

        let adoptionBelow = CapacitySequence([36, 19])
        let adoptionPreflight = makePreflight(capacity: { try adoptionBelow.next() })
        let adoptionPrepared = try await adoptionPreflight.prepare(
            videoURLs: [source],
            stagingParent: library,
            requiredAtomicWorkspaceReserveBytes: 20,
            progress: { _, _ in }
        )
        defer { adoptionPrepared.discard() }
        let secondProject = library.appendingPathComponent("Below.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: secondProject, withIntermediateDirectories: false)
        XCTAssertThrowsError(
            try adoptionPrepared.adopt(into: ProjectPaths(root: secondProject).originalsURL)
        ) { error in
            XCTAssertEqual(
                (error as? VideoInputPreflightFailure)?.rejectedVideos.first?.issue,
                .insufficientSpace(required: 20, available: 19)
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ProjectPaths(root: secondProject).originalsURL.path
            )
        )
    }

    func testAtomicWorkspaceReserveTracksMeasuredFormatsWithoutUncompressedInflation() {
        let measuredProof = VideoInputPreflight.requiredAtomicWorkspaceReserveBytes(
            keyframeBudget: 250,
            maximumImageDimension: 1_600,
            maximumFeatureCount: 8_192,
            maximumMatchCount: 8_192,
            retrievalCandidateCount: 20
        )
        let highDetail = VideoInputPreflight.requiredAtomicWorkspaceReserveBytes(
            keyframeBudget: 500,
            maximumImageDimension: 2_048,
            maximumFeatureCount: 8_192,
            maximumMatchCount: 8_192,
            retrievalCandidateCount: 20
        )

        XCTAssertEqual(measuredProof, 4_444_265_472)
        XCTAssertEqual(highDetail, 5_973_737_472)
        XCTAssertLessThan(measuredProof, 5 * 1_024 * 1_024 * 1_024)
        XCTAssertLessThan(highDetail, 7 * 1_024 * 1_024 * 1_024)
        XCTAssertEqual(
            VideoInputPreflight.requiredAtomicWorkspaceReserveBytes(
                keyframeBudget: 30,
                maximumImageDimension: 960,
                maximumFeatureCount: 4_096,
                maximumMatchCount: 4_096,
                retrievalCandidateCount: 12
            ),
            4 * 1_024 * 1_024 * 1_024,
            "A constrained 30-view Fast run should retain the atomic-output floor, not a multi-copy image estimate."
        )
        XCTAssertEqual(
            VideoInputPreflight.requiredAtomicWorkspaceReserveBytes(
                keyframeBudget: Int.max,
                maximumImageDimension: Int.max
            ),
            Int64.max
        )
    }

    func testDistinctFilesWithIdenticalBytesAreRejectedBeforeDecode() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let first = root.appendingPathComponent("first.mov")
        let second = root.appendingPathComponent("second.mov")
        try Data("same-video".utf8).write(to: first)
        try Data("same-video".utf8).write(to: second)
        let analyses = LockedCounter()
        let preflight = makePreflight(
            capacity: { 1_000_000 },
            analyze: { _, _ in
                analyses.increment()
                return .fixture
            }
        )

        do {
            _ = try await preflight.prepare(
                videoURLs: [first, second],
                stagingParent: library,
                requiredAtomicWorkspaceReserveBytes: 0,
                progress: { _, _ in }
            )
            XCTFail("Byte-identical selections must be rejected")
        } catch let failure as VideoInputPreflightFailure {
            XCTAssertEqual(
                failure.rejectedVideos,
                [VideoInputRejection(
                    index: 1,
                    safeDisplayName: "second.mov",
                    issue: .duplicateSource(firstIndex: 0)
                )]
            )
        }
        XCTAssertEqual(analyses.value, 0)
    }

    func testCloneFastPathAndStreamingFallbackProduceIdenticalSnapshots() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("capture.mov")
        let bytes = Data((0..<16_384).map { UInt8($0 % 251) })
        try bytes.write(to: source)
        let cloneLibrary = root.appendingPathComponent("CloneProjects", isDirectory: true)
        let streamLibrary = root.appendingPathComponent("StreamProjects", isDirectory: true)
        try FileManager.default.createDirectory(at: cloneLibrary, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: streamLibrary, withIntermediateDirectories: true)
        let cloneRecorder = ClonePathRecorder(mode: .clone)
        let streamRecorder = ClonePathRecorder(mode: .fallback)

        let cloned = try await makePreflight(
            capacity: { 1_000_000 },
            cloneSnapshot: cloneRecorder.perform
        ).prepare(
            videoURLs: [source],
            stagingParent: cloneLibrary,
            requiredAtomicWorkspaceReserveBytes: 0,
            progress: { _, _ in }
        )
        defer { cloned.discard() }
        let streamed = try await makePreflight(
            capacity: { 1_000_000 },
            cloneSnapshot: streamRecorder.perform
        ).prepare(
            videoURLs: [source],
            stagingParent: streamLibrary,
            requiredAtomicWorkspaceReserveBytes: 0,
            progress: { _, _ in }
        )
        defer { streamed.discard() }

        XCTAssertEqual(cloneRecorder.count, 1)
        XCTAssertEqual(streamRecorder.count, 1)
        XCTAssertEqual(try Data(contentsOf: cloned.videos[0].stagedURL), bytes)
        XCTAssertEqual(try Data(contentsOf: streamed.videos[0].stagedURL), bytes)
        XCTAssertEqual(cloned.videos[0].sha256, streamed.videos[0].sha256)
        XCTAssertEqual(try posixMode(of: cloned.videos[0].stagedURL), 0o600)
        XCTAssertEqual(try posixMode(of: streamed.videos[0].stagedURL), 0o600)
    }

    func testCloneFastPathAcceptsOwnerReadableSourceWithoutWritePermission() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("read-only.mov")
        let bytes = Data("read-only-video".utf8)
        try bytes.write(to: source)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: source.path
        )
        let cloneRecorder = ClonePathRecorder(mode: .clone)

        let prepared = try await makePreflight(
            capacity: { 1_000_000 },
            cloneSnapshot: cloneRecorder.perform
        ).prepare(
            videoURLs: [source],
            stagingParent: library,
            requiredAtomicWorkspaceReserveBytes: 0,
            progress: { _, _ in }
        )
        defer { prepared.discard() }

        XCTAssertEqual(cloneRecorder.count, 1)
        XCTAssertEqual(try posixMode(of: source), 0o400)
        XCTAssertEqual(try posixMode(of: prepared.videos[0].stagedURL), 0o600)
        XCTAssertEqual(try Data(contentsOf: prepared.videos[0].stagedURL), bytes)
    }

    func testCloneMutationBeforeDestinationMonitorRegistrationIsRejected() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("capture.mov")
        let sourceBytes = Data("original-clone-bytes".utf8)
        let substitutedBytes = Data("substitute-clone-byt".utf8)
        XCTAssertEqual(sourceBytes.count, substitutedBytes.count)
        try sourceBytes.write(to: source)
        let analyses = LockedCounter()

        let preflight = VideoInputPreflight(
            limits: testLimits,
            availableCapacity: { _ in 1_000_000 },
            analyze: { _, _ in
                analyses.increment()
                return .fixture
            },
            cloneSnapshot: { sourceDescriptor, destinationDirectory, leaf in
                let cloneResult = leaf.withCString {
                    fclonefileat(
                        sourceDescriptor,
                        destinationDirectory,
                        $0,
                        UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)
                    )
                }
                guard cloneResult == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                let destinationDescriptor = leaf.withCString {
                    openat(destinationDirectory, $0, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
                }
                guard destinationDescriptor >= 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                defer { Darwin.close(destinationDescriptor) }
                let written = substitutedBytes.withUnsafeBytes {
                    pwrite(destinationDescriptor, $0.baseAddress, $0.count, 0)
                }
                guard written == substitutedBytes.count, fsync(destinationDescriptor) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                return true
            }
        )

        do {
            _ = try await preflight.prepare(
                videoURLs: [source],
                stagingParent: library,
                requiredAtomicWorkspaceReserveBytes: 0,
                progress: { _, _ in }
            )
            XCTFail("A clone changed before monitor registration must not be authenticated")
        } catch let failure as VideoInputPreflightFailure {
            XCTAssertEqual(failure.rejectedVideos.first?.issue, .copyFailed)
        }
        XCTAssertEqual(analyses.value, 0)
    }

    func testStagedMutationDuringDecodeCannotAcquireValidEvidence() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("capture.mov")
        try Data("original-bytes".utf8).write(to: source)
        let preflight = makePreflight(
            capacity: { 1_000_000 },
            analyze: { url, _ in
                let moved = url.deletingLastPathComponent().appendingPathComponent("moved.mov")
                try FileManager.default.moveItem(at: url, to: moved)
                try Data("changed--bytes".utf8).write(to: url)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: url.path
                )
                return .fixture
            }
        )

        do {
            _ = try await preflight.prepare(
                videoURLs: [source],
                stagingParent: library,
                requiredAtomicWorkspaceReserveBytes: 0,
                progress: { _, _ in }
            )
            XCTFail("Decode evidence must remain bound to the copied inode and digest")
        } catch let failure as VideoInputPreflightFailure {
            XCTAssertEqual(failure.rejectedVideos.first?.issue, .copyFailed)
        }
    }

    func testEveryStagedFileMutationClassIsRejectedDuringAnalysis() async throws {
        enum Mutation: CaseIterable {
            case sameSizeWrite
            case append
            case truncate
            case chmod
            case attributes
            case rename
            case unlink
            case hardLink
            case renameAwayAndRestore
        }

        for mutation in Mutation.allCases {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let library = root.appendingPathComponent("Projects", isDirectory: true)
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("capture.mov")
            try Data("authenticated-video".utf8).write(to: source)
            let preflight = makePreflight(
                capacity: { 1_000_000 },
                analyze: { url, _ in
                    let sibling = url.deletingLastPathComponent()
                        .appendingPathComponent("mutation.mov")
                    switch mutation {
                    case .sameSizeWrite:
                        let descriptor = Darwin.open(url.path, O_WRONLY | O_CLOEXEC)
                        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
                        defer { Darwin.close(descriptor) }
                        let replacement = Array("AUTHENTICATED-VIDEO".utf8)
                        guard replacement.count == Int((try FileManager.default.attributesOfItem(
                            atPath: url.path
                        )[.size] as? NSNumber)?.int64Value ?? -1),
                              replacement.withUnsafeBytes({
                                  pwrite(descriptor, $0.baseAddress, $0.count, 0)
                              }) == replacement.count,
                              fsync(descriptor) == 0 else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                    case .append:
                        let handle = try FileHandle(forWritingTo: url)
                        try handle.seekToEnd()
                        try handle.write(contentsOf: Data([0x41]))
                        try handle.synchronize()
                        try handle.close()
                    case .truncate:
                        guard Darwin.truncate(url.path, 4) == 0 else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                    case .chmod:
                        guard Darwin.chmod(url.path, 0o400) == 0 else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                    case .attributes:
                        try FileManager.default.setAttributes(
                            [.modificationDate: Date(timeIntervalSince1970: 1)],
                            ofItemAtPath: url.path
                        )
                    case .rename:
                        try FileManager.default.moveItem(at: url, to: sibling)
                    case .unlink:
                        try FileManager.default.removeItem(at: url)
                    case .hardLink:
                        guard Darwin.link(url.path, sibling.path) == 0 else {
                            throw CocoaError(.fileWriteUnknown)
                        }
                    case .renameAwayAndRestore:
                        try FileManager.default.moveItem(at: url, to: sibling)
                        try FileManager.default.moveItem(at: sibling, to: url)
                    }
                    return .fixture
                }
            )

            do {
                _ = try await preflight.prepare(
                    videoURLs: [source],
                    stagingParent: library,
                    requiredAtomicWorkspaceReserveBytes: 0,
                    progress: { _, _ in }
                )
                XCTFail("\(mutation) must invalidate staged evidence")
            } catch let failure as VideoInputPreflightFailure {
                XCTAssertEqual(failure.rejectedVideos.first?.issue, .copyFailed, "\(mutation)")
            }
        }
    }

    func testMutationDuringProjectionProbeIsRejectedBeforeDecode() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("capture.mov")
        try Data("projection-video".utf8).write(to: source)
        let analyses = LockedCounter()
        let preflight = VideoInputPreflight(
            limits: testLimits,
            availableCapacity: { _ in 1_000_000 },
            analyze: { _, _ in
                analyses.increment()
                return .fixture
            },
            projectionProbe: { url in
                let descriptor = Darwin.open(url.path, O_WRONLY | O_CLOEXEC)
                guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
                defer { Darwin.close(descriptor) }
                let replacement = Array("PROJECTION-VIDEO".utf8)
                guard replacement.withUnsafeBytes({
                    pwrite(descriptor, $0.baseAddress, $0.count, 0)
                }) == replacement.count,
                      fsync(descriptor) == 0 else {
                    throw CocoaError(.fileWriteUnknown)
                }
                return nil
            }
        )

        do {
            _ = try await preflight.prepare(
                videoURLs: [source],
                stagingParent: library,
                requiredAtomicWorkspaceReserveBytes: 0,
                progress: { _, _ in }
            )
            XCTFail("Projection must not authorize mutated bytes")
        } catch let failure as VideoInputPreflightFailure {
            XCTAssertEqual(failure.rejectedVideos.first?.issue, .copyFailed)
        }
        XCTAssertEqual(analyses.value, 0)
    }

    func testMutationBeforeAdoptOrDiscardPreservesSuspiciousStagingTree() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("capture.mov")
        try Data("video".utf8).write(to: source)

        let adoptPrepared = try await makePreflight(capacity: { 1_000_000 }).prepare(
            videoURLs: [source],
            stagingParent: library,
            requiredAtomicWorkspaceReserveBytes: 0,
            progress: { _, _ in }
        )
        try Data("other".utf8).write(to: adoptPrepared.videos[0].stagedURL)
        let project = library.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        XCTAssertThrowsError(
            try adoptPrepared.adopt(into: ProjectPaths(root: project).originalsURL)
        ) { error in
            XCTAssertEqual(
                (error as? VideoInputPreflightFailure)?.rejectedVideos.first?.issue,
                .copyFailed
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: adoptPrepared.stagingRoot.path))

        let discardPrepared = try await makePreflight(capacity: { 1_000_000 }).prepare(
            videoURLs: [source],
            stagingParent: library,
            requiredAtomicWorkspaceReserveBytes: 0,
            progress: { _, _ in }
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: discardPrepared.videos[0].stagedURL.path
        )
        discardPrepared.discard()
        XCTAssertTrue(FileManager.default.fileExists(atPath: discardPrepared.stagingRoot.path))
    }

    func testMutationAtFinalDiscardBoundaryPreservesStagingTree() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("capture.mov")
        try Data("discard-video".utf8).write(to: source)
        let preflight = VideoInputPreflight(
            limits: testLimits,
            availableCapacity: { _ in 1_000_000 },
            analyze: { _, _ in .fixture },
            discardBoundary: { stagingRoot in
                let video = stagingRoot.appendingPathComponent("video-0000.mov")
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o400],
                    ofItemAtPath: video.path
                )
            }
        )
        let prepared = try await preflight.prepare(
            videoURLs: [source],
            stagingParent: library,
            requiredAtomicWorkspaceReserveBytes: 0,
            progress: { _, _ in }
        )

        prepared.discard()

        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.stagingRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.videos[0].stagedURL.path))
    }

    func testMonitorSetupFailureFailsClosedBeforeAnalysis() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("capture.mov")
        try Data("fallback-video".utf8).write(to: source)
        let analyses = LockedCounter()
        let preflight = VideoInputPreflight(
            limits: testLimits,
            availableCapacity: { _ in 1_000_000 },
            analyze: { _, _ in
                analyses.increment()
                return .fixture
            },
            monitorFactory: { _ in throw VnodeMutationMonitor.Failure.unsupportedPlatform }
        )

        do {
            _ = try await preflight.prepare(
                videoURLs: [source],
                stagingParent: library,
                requiredAtomicWorkspaceReserveBytes: 0,
                progress: { _, _ in }
            )
            XCTFail("Unmonitored async analysis must never run")
        } catch let failure as VideoInputPreflightFailure {
            XCTAssertEqual(failure.rejectedVideos.first?.issue, .copyFailed)
        }
        XCTAssertEqual(analyses.value, 0)
    }

    func testTransientDirectoryEntryMutationIsSticky() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("capture.mov")
        try Data("directory-video".utf8).write(to: source)
        let preflight = makePreflight(
            capacity: { 1_000_000 },
            analyze: { url, _ in
                let transient = url.deletingLastPathComponent()
                    .appendingPathComponent("transient")
                try Data("temporary".utf8).write(to: transient)
                try FileManager.default.removeItem(at: transient)
                return .fixture
            }
        )

        do {
            _ = try await preflight.prepare(
                videoURLs: [source],
                stagingParent: library,
                requiredAtomicWorkspaceReserveBytes: 0,
                progress: { _, _ in }
            )
            XCTFail("A restored directory listing must not clear vnode evidence")
        } catch let failure as VideoInputPreflightFailure {
            XCTAssertEqual(failure.rejectedVideos.first?.issue, .copyFailed)
        }
    }

    func testClonePathAuthenticatesStagedOutputAndRetainedSourceSeparately() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("capture.mov")
        try Data("clone-content-authentication".utf8).write(to: source)
        let cloneRecorder = ClonePathRecorder(mode: .clone)
        let contentPasses = ContentPassRecorder()
        let preflight = VideoInputPreflight(
            limits: testLimits,
            availableCapacity: { _ in 1_000_000 },
            analyze: { _, _ in .fixture },
            cloneSnapshot: cloneRecorder.perform,
            contentPassObserver: { pass, url in contentPasses.append(pass, url: url) }
        )

        let prepared = try await preflight.prepare(
            videoURLs: [source],
            stagingParent: library,
            requiredAtomicWorkspaceReserveBytes: 0,
            progress: { _, _ in }
        )
        defer { prepared.discard() }
        XCTAssertEqual(cloneRecorder.count, 1)
        XCTAssertEqual(
            contentPasses.passes,
            [.stagedOutputAuthentication, .retainedCloneSourceAuthentication]
        )
        XCTAssertEqual(contentPasses.urls, [prepared.videos[0].stagedURL, source])
    }

    func testStreamingPathRecordsCopyDigestAndStagedAuthenticationSeparately() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("capture.mov")
        try Data("stream-content-authentication".utf8).write(to: source)
        let streamRecorder = ClonePathRecorder(mode: .fallback)
        let contentPasses = ContentPassRecorder()
        let preflight = VideoInputPreflight(
            limits: testLimits,
            availableCapacity: { _ in 1_000_000 },
            analyze: { _, _ in .fixture },
            cloneSnapshot: streamRecorder.perform,
            contentPassObserver: { pass, url in contentPasses.append(pass, url: url) }
        )

        let prepared = try await preflight.prepare(
            videoURLs: [source],
            stagingParent: library,
            requiredAtomicWorkspaceReserveBytes: 0,
            progress: { _, _ in }
        )
        defer { prepared.discard() }
        XCTAssertEqual(streamRecorder.count, 1)
        XCTAssertEqual(
            contentPasses.passes,
            [.streamingSourceCopyAndDigest, .stagedOutputAuthentication]
        )
        XCTAssertEqual(contentPasses.urls, [source, prepared.videos[0].stagedURL])
    }

    func testMutationAtCanonicalContentPassBoundaryIsRejected() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("capture.mov")
        try Data("boundary-video".utf8).write(to: source)
        let analyses = LockedCounter()
        let preflight = VideoInputPreflight(
            limits: testLimits,
            availableCapacity: { _ in 1_000_000 },
            analyze: { _, _ in
                analyses.increment()
                return .fixture
            },
            contentPassObserver: { pass, url in
                guard pass == .stagedOutputAuthentication else { return }
                try? Data("BOUNDARY-VIDEO".utf8).write(to: url)
            }
        )

        do {
            _ = try await preflight.prepare(
                videoURLs: [source],
                stagingParent: library,
                requiredAtomicWorkspaceReserveBytes: 0,
                progress: { _, _ in }
            )
            XCTFail("The canonical pass must already be monitored")
        } catch let failure as VideoInputPreflightFailure {
            XCTAssertEqual(failure.rejectedVideos.first?.issue, .copyFailed)
        }
        XCTAssertEqual(analyses.value, 0)
    }

    func testCancellationDuringAnalysisRemainsCancellationError() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("capture.mov")
        try Data("cancel-video".utf8).write(to: source)
        let preflight = makePreflight(
            capacity: { 1_000_000 },
            analyze: { _, _ in throw CancellationError() }
        )

        do {
            _ = try await preflight.prepare(
                videoURLs: [source],
                stagingParent: library,
                requiredAtomicWorkspaceReserveBytes: 0,
                progress: { _, _ in }
            )
            XCTFail("Cancellation must escape as CancellationError")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStructuralFailuresAggregateInSelectionOrderBeforeStaging() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let valid = root.appendingPathComponent("valid.mov")
        let missing = root.appendingPathComponent("gone\nclient.mov")
        let alias = root.appendingPathComponent("alias.mov")
        let empty = root.appendingPathComponent("empty.mov")
        try Data("video".utf8).write(to: valid)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: valid)
        FileManager.default.createFile(atPath: empty.path, contents: Data())

        do {
            _ = try await makePreflight(capacity: { 1_000_000 }).prepare(
                videoURLs: [valid, missing, alias, empty, valid],
                stagingParent: library,
                requiredAtomicWorkspaceReserveBytes: 0,
                progress: { _, _ in }
            )
            XCTFail("Every structural rejection should be reported")
        } catch let failure as VideoInputPreflightFailure {
            XCTAssertEqual(failure.rejectedVideos.map(\.index), [1, 2, 3, 4])
            XCTAssertEqual(
                failure.rejectedVideos.map(\.issue),
                [
                    .sourceUnavailable,
                    .symbolicLink,
                    .emptyFile,
                    .duplicateSource(firstIndex: 0),
                ]
            )
            XCTAssertEqual(failure.rejectedVideos[0].safeDisplayName, "gone client.mov")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: library.appendingPathComponent(
                    VideoInputPreflight.stagingParentName
                ).path
            )
        )
    }

    func testSourcePathSwapAfterInspectionIsRejected() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("capture.mov")
        try Data("original".utf8).write(to: source)
        let swapped = LockedFlag()

        do {
            _ = try await makePreflight(capacity: { 1_000_000 }).prepare(
                videoURLs: [source],
                stagingParent: library,
                requiredAtomicWorkspaceReserveBytes: 0,
                progress: { _, message in
                    guard message.hasPrefix("Copying"), swapped.setIfFalse() else { return }
                    let original = source.deletingLastPathComponent()
                        .appendingPathComponent("original.mov")
                    try? FileManager.default.moveItem(at: source, to: original)
                    try? Data("replaced".utf8).write(to: source)
                }
            )
            XCTFail("A swapped source path must not be copied")
        } catch let failure as VideoInputPreflightFailure {
            XCTAssertEqual(failure.rejectedVideos.first?.issue, .sourceChanged)
        }
    }

    func testDiscardRefusesSwappedStagingRoot() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("capture.mov")
        try Data("video".utf8).write(to: source)
        let prepared = try await makePreflight(capacity: { 1_000_000 }).prepare(
            videoURLs: [source],
            stagingParent: library,
            requiredAtomicWorkspaceReserveBytes: 0,
            progress: { _, _ in }
        )
        let genuine = prepared.stagingRoot.deletingLastPathComponent()
            .appendingPathComponent("genuine-run")
        try FileManager.default.moveItem(at: prepared.stagingRoot, to: genuine)
        try FileManager.default.createDirectory(
            at: prepared.stagingRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let replacement = prepared.stagingRoot.appendingPathComponent("video-0000.mov")
        try Data("other".utf8).write(to: replacement)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: replacement.path
        )

        prepared.discard()

        XCTAssertTrue(FileManager.default.fileExists(atPath: prepared.stagingRoot.path))
        XCTAssertEqual(try Data(contentsOf: replacement), Data("other".utf8))
    }

    func testConcurrentAdoptAndDiscardResolveToOneOwnedOutcome() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

        for iteration in 0..<20 {
            let source = root.appendingPathComponent("capture-\(iteration).mov")
            let bytes = Data("video-\(iteration)".utf8)
            try bytes.write(to: source)
            let prepared = try await makePreflight(capacity: { 1_000_000 }).prepare(
                videoURLs: [source],
                stagingParent: library,
                requiredAtomicWorkspaceReserveBytes: 0,
                progress: { _, _ in }
            )
            let project = library.appendingPathComponent(
                "Race-\(iteration).easysplatproj",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
            let originals = ProjectPaths(root: project).originalsURL

            let adoptionSucceeded = await withTaskGroup(of: Bool.self) { group in
                group.addTask {
                    do {
                        _ = try prepared.adopt(into: originals)
                        return true
                    } catch {
                        return false
                    }
                }
                group.addTask {
                    prepared.discard()
                    return false
                }
                var succeeded = false
                for await result in group {
                    succeeded = succeeded || result
                }
                return succeeded
            }

            XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.stagingRoot.path))
            XCTAssertEqual(FileManager.default.fileExists(atPath: originals.path), adoptionSucceeded)
            if adoptionSucceeded {
                XCTAssertEqual(
                    try Data(contentsOf: originals.appendingPathComponent("video-0000.mov")),
                    bytes
                )
            }
        }
    }

    func testStaleCleanupRemovesOnlyStrictOwnedRunShape() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let container = library.appendingPathComponent(VideoInputPreflight.stagingParentName)
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let stale = container.appendingPathComponent("run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: stale,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let staleVideo = stale.appendingPathComponent("video-0000.mov")
        try Data("stale".utf8).write(to: staleVideo)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: staleVideo.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -48 * 60 * 60)],
            ofItemAtPath: stale.path
        )
        let protected = container.appendingPathComponent("run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: protected,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o755]
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -48 * 60 * 60)],
            ofItemAtPath: protected.path
        )
        let unicodeProtected = container.appendingPathComponent("run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: unicodeProtected,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let unicodeLeaf = unicodeProtected.appendingPathComponent("video-１２３４.mov")
        try Data("not app-owned".utf8).write(to: unicodeLeaf)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: unicodeLeaf.path
        )
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -48 * 60 * 60)],
            ofItemAtPath: unicodeProtected.path
        )
        let source = root.appendingPathComponent("capture.mov")
        try Data("fresh".utf8).write(to: source)

        let prepared = try await makePreflight(capacity: { 1_000_000 }).prepare(
            videoURLs: [source],
            stagingParent: library,
            requiredAtomicWorkspaceReserveBytes: 0,
            progress: { _, _ in }
        )
        defer { prepared.discard() }

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: protected.path))
        XCTAssertEqual(try Data(contentsOf: unicodeLeaf), Data("not app-owned".utf8))
    }

    func testPrepareAggregatesDecodeFailuresInInputOrderAndBoundsConcurrency() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let sources = try ["good.mov", "bad-one.mov", "bad-two.mov"].enumerated().map {
            index, name in
            let url = root.appendingPathComponent(name)
            try Data(index == 0 ? "good".utf8 : "bad-\(index)".utf8).write(to: url)
            return url
        }
        let meter = ConcurrencyRecorder()
        let preflight = VideoInputPreflight(
            limits: .init(
                maximumVideoCount: 4,
                maximumTotalBytes: 1_024 * 1_024,
                minimumFreeSpaceReserveBytes: 0,
                maximumConcurrentDecoders: 2
            ),
            availableCapacity: { _ in 1_024 * 1_024 },
            analyze: { url, _ in
                await meter.enter()
                defer { Task { await meter.leave() } }
                try await Task.sleep(for: .milliseconds(25))
                if try Data(contentsOf: url) != Data("good".utf8) {
                    throw FrameExtractor.ExtractionError.extractionFailed
                }
                return VideoInputAnalysisEvidence(
                    trackID: 1,
                    pixelWidth: 64,
                    pixelHeight: 48,
                    durationSeconds: 1,
                    nominalFrameRate: 30,
                    isHDR: false,
                    decodedFrameCount: 3,
                    preferredTransform: .identity
                )
            }
        )

        do {
            _ = try await preflight.prepare(
                videoURLs: sources,
                stagingParent: library,
                requiredAtomicWorkspaceReserveBytes: 0,
                progress: { _, _ in }
            )
            XCTFail("Corrupt videos must fail preflight")
        } catch let failure as VideoInputPreflightFailure {
            XCTAssertEqual(
                failure.rejectedVideos,
                [
                    VideoInputRejection(
                        index: 1,
                        safeDisplayName: "bad-one.mov",
                        issue: .decodeFailed
                    ),
                    VideoInputRejection(
                        index: 2,
                        safeDisplayName: "bad-two.mov",
                        issue: .decodeFailed
                    ),
                ]
            )
        }

        let peak = await meter.peak
        XCTAssertLessThanOrEqual(peak, 2)
        let stagingContainer = library.appendingPathComponent(
            VideoInputPreflight.stagingParentName,
            isDirectory: true
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: stagingContainer.path),
            []
        )
    }

    func testDefaultAnalyzerFullyDecodesGeneratedH264MOVAndMP4() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let times = (0..<18).map { Double($0) / 30 }
        let levels = times.indices.map { UInt8(32 + $0 * 8) }
        let mov = root.appendingPathComponent("capture.mov")
        let mp4 = root.appendingPathComponent("capture.mp4")
        do {
            try await TestVideoBuilder.writeH264(
                to: mov,
                times: times,
                levels: levels,
                keyFrameInterval: 6,
                requireH264: true,
                fileType: .mov,
                transform: CGAffineTransform(rotationAngle: .pi / 2)
            )
            try await TestVideoBuilder.writeH264(
                to: mp4,
                times: times,
                levels: levels,
                keyFrameInterval: 6,
                requireH264: true,
                fileType: .mp4
            )
        } catch TestVideoBuilder.FixtureError.unsupportedCodec(let reason) {
            throw XCTSkip(reason)
        }
        let preflight = VideoInputPreflight(limits: .init(
            maximumVideoCount: 4,
            maximumTotalBytes: 64 * 1_024 * 1_024,
            minimumFreeSpaceReserveBytes: 0,
            maximumConcurrentDecoders: 2
        ))

        let prepared = try await preflight.prepare(
            videoURLs: [mov, mp4],
            stagingParent: library,
            requiredAtomicWorkspaceReserveBytes: 0,
            progress: { _, _ in }
        )
        defer { prepared.discard() }

        XCTAssertEqual(prepared.videos.map(\.decodedFrameCount), [times.count, times.count])
        XCTAssertEqual(prepared.videos[0].pixelWidth, 64)
        XCTAssertEqual(prepared.videos[0].pixelHeight, 48)
        XCTAssertEqual(prepared.videos[0].transformA, 0, accuracy: 0.0001)
        XCTAssertEqual(abs(prepared.videos[0].transformB), 1, accuracy: 0.0001)
        XCTAssertEqual(prepared.videos.map { $0.stagedURL.pathExtension }, ["mov", "mp4"])
    }

    func testDefaultAnalyzerRejectsFinalGOPCorruptionBeforeHandoff() async throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("truncated.mov")
        let times = (0..<60).map { Double($0) / 30 }
        do {
            try await TestVideoBuilder.writeH264(
                to: source,
                times: times,
                levels: times.indices.map { UInt8(16 + $0 % 220) },
                keyFrameInterval: 15,
                requireH264: true
            )
        } catch TestVideoBuilder.FixtureError.unsupportedCodec(let reason) {
            throw XCTSkip(reason)
        }
        try corruptFinalMediaPayload(at: source)
        let parsed = try await FrameExtractor().inspect(source)
        XCTAssertEqual(parsed.primaryTrack.width, 64)
        XCTAssertEqual(parsed.primaryTrack.height, 48)
        let preflight = VideoInputPreflight(limits: .init(
            maximumVideoCount: 2,
            maximumTotalBytes: 64 * 1_024 * 1_024,
            minimumFreeSpaceReserveBytes: 0,
            maximumConcurrentDecoders: 2
        ))

        do {
            _ = try await preflight.prepare(
                videoURLs: [source],
                stagingParent: library,
                requiredAtomicWorkspaceReserveBytes: 0,
                progress: { _, _ in }
            )
            XCTFail("An H.264 file with a corrupt final GOP must not pass preflight")
        } catch let failure as VideoInputPreflightFailure {
            XCTAssertEqual(failure.rejectedVideos.count, 1)
            XCTAssertEqual(failure.rejectedVideos[0].issue, .decodeFailed)
        }
        let staging = library.appendingPathComponent(VideoInputPreflight.stagingParentName)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
    }

    private func posixMode(of url: URL) throws -> mode_t {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return status.st_mode & mode_t(0o7777)
    }

    private func corruptFinalMediaPayload(at url: URL) throws {
        var data = try Data(contentsOf: url)
        var offset = 0
        var mediaPayload: Range<Int>?
        while offset + 8 <= data.count {
            let size32 = data[offset..<(offset + 4)].reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
            let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            var headerSize = 8
            let atomSize: Int
            if size32 == 1 {
                guard offset + 16 <= data.count else { break }
                let size64 = data[(offset + 8)..<(offset + 16)].reduce(UInt64(0)) {
                    ($0 << 8) | UInt64($1)
                }
                guard size64 <= UInt64(Int.max) else { break }
                atomSize = Int(size64)
                headerSize = 16
            } else if size32 == 0 {
                atomSize = data.count - offset
            } else {
                atomSize = Int(size32)
            }
            guard atomSize >= headerSize, offset + atomSize <= data.count else { break }
            if type == "mdat" {
                mediaPayload = (offset + headerSize)..<(offset + atomSize)
            }
            offset += atomSize
        }
        let payload = try XCTUnwrap(mediaPayload)
        let corruptCount = max(1, payload.count / 3)
        for index in (payload.upperBound - corruptCount)..<payload.upperBound {
            data[index] = 0
        }
        try data.write(to: url, options: [.atomic])
    }

    private var testLimits: VideoInputPreflightLimits {
        VideoInputPreflightLimits(
            maximumVideoCount: 64,
            maximumTotalBytes: 1_024 * 1_024,
            minimumFreeSpaceReserveBytes: 0,
            maximumConcurrentDecoders: 2
        )
    }

    private func makePreflight(
        capacity: @escaping @Sendable () throws -> Int64,
        analyze: @escaping VideoInputPreflight.Analyze = { _, _ in .fixture },
        cloneSnapshot: VideoInputPreflight.CloneSnapshot? = nil
    ) -> VideoInputPreflight {
        let limits = testLimits
        if let cloneSnapshot {
            return VideoInputPreflight(
                limits: limits,
                availableCapacity: { _ in try capacity() },
                analyze: analyze,
                cloneSnapshot: cloneSnapshot
            )
        }
        return VideoInputPreflight(
            limits: limits,
            availableCapacity: { _ in try capacity() },
            analyze: analyze
        )
    }
}

private actor ConcurrencyRecorder {
    private var current = 0
    private(set) var peak = 0

    func enter() {
        current += 1
        peak = max(peak, current)
    }

    func leave() {
        current -= 1
    }
}

private final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    var values: [URL] {
        lock.withLock { storage }
    }

    func append(_ value: URL) {
        lock.withLock { storage.append(value) }
    }
}

private final class CapacitySequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64]

    init(_ values: [Int64]) {
        self.values = values
    }

    func next() throws -> Int64 {
        try lock.withLock {
            guard !values.isEmpty else { throw VideoInputCapacityEvidenceError.unavailable }
            return values.removeFirst()
        }
    }
}

private final class AdoptionDestinationRace: @unchecked Sendable {
    private let lock = NSLock()
    private var destination: URL?
    private var fired = false

    func arm(destination: URL) {
        lock.withLock { self.destination = destination }
    }

    func availableCapacity() throws -> Int64 {
        let destinationToCreate = lock.withLock { () -> URL? in
            guard let destination, !fired else { return nil }
            fired = true
            return destination
        }
        if let destinationToCreate {
            try FileManager.default.createDirectory(
                at: destinationToCreate,
                withIntermediateDirectories: false
            )
        }
        return 1_000_000
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func setIfFalse() -> Bool {
        lock.withLock {
            guard !value else { return false }
            value = true
            return true
        }
    }
}

private final class ContentPassRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPasses: [VideoInputPreflight.ContentPass] = []
    private var storedURLs: [URL] = []

    var passes: [VideoInputPreflight.ContentPass] {
        lock.withLock { storedPasses }
    }

    var urls: [URL] {
        lock.withLock { storedURLs }
    }

    func append(_ pass: VideoInputPreflight.ContentPass, url: URL) {
        lock.withLock {
            storedPasses.append(pass)
            storedURLs.append(url)
        }
    }
}

private final class ClonePathRecorder: @unchecked Sendable {
    enum Mode {
        case clone
        case fallback
    }

    private let lock = NSLock()
    private let mode: Mode
    private var storage = 0

    init(mode: Mode) {
        self.mode = mode
    }

    var count: Int { lock.withLock { storage } }

    func perform(source: Int32, destinationDirectory: Int32, leaf: String) throws -> Bool {
        lock.withLock { storage += 1 }
        guard mode == .clone else { return false }
        let result = leaf.withCString {
            fclonefileat(
                source,
                destinationDirectory,
                $0,
                UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)
            )
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return true
    }
}

private extension VideoInputAnalysisEvidence {
    static let fixture = VideoInputAnalysisEvidence(
        trackID: 1,
        pixelWidth: 64,
        pixelHeight: 48,
        durationSeconds: 1,
        nominalFrameRate: 30,
        isHDR: false,
        decodedFrameCount: 3,
        preferredTransform: .identity
    )
}

private final class FrameExtractionOptionsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: FrameExtractionOptions?

    var value: FrameExtractionOptions? {
        lock.withLock { stored }
    }

    func record(_ options: FrameExtractionOptions) {
        lock.withLock { stored = options }
    }
}

private extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
