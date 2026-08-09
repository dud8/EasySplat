import CryptoKit
import Darwin
import XCTest
@testable import EasySplatCore

final class SubjectIsolationCoordinatorTests: XCTestCase {
    func testCrossProcessRetirementHelperEntryPoint() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment["EASYSPLAT_SUBJECT_LEASE_HELPER_MODE"] else {
            return
        }

        if mode == "hold-legacy-ofd" {
            guard let lockPath = environment["EASYSPLAT_SUBJECT_LEASE_HELPER_LOCK"],
                  let readyPath = environment["EASYSPLAT_SUBJECT_LEASE_HELPER_READY"],
                  let releasePath = environment["EASYSPLAT_SUBJECT_LEASE_HELPER_RELEASE"] else {
                throw CoordinatorProbeError.expectedFailure
            }
            try holdLegacyOFDLock(
                lockPath: lockPath,
                readyPath: readyPath,
                releasePath: releasePath
            )
            return
        }

        guard mode == "retire",
              let projectPath = environment["EASYSPLAT_SUBJECT_LEASE_HELPER_PROJECT"],
              let attemptedPath = environment["EASYSPLAT_SUBJECT_LEASE_HELPER_ATTEMPTED"],
              let readyPath = environment["EASYSPLAT_SUBJECT_LEASE_HELPER_READY"],
              let completedPath = environment["EASYSPLAT_SUBJECT_LEASE_HELPER_COMPLETED"] else {
            throw CoordinatorProbeError.expectedFailure
        }

        let ready = Darwin.open(readyPath, O_WRONLY | O_CLOEXEC)
        guard ready >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(ready) }
        try SubjectIsolationCoordinator.cancelPendingAmbiguity(
            projectPaths: ProjectPaths(root: URL(fileURLWithPath: projectPath)),
            beforeOwnedStagingRemoval: { _ in },
            onLockContention: {
                let attempted = Darwin.open(
                    attemptedPath,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                    mode_t(0o600)
                )
                guard attempted >= 0 else { return }
                Darwin.close(attempted)
                var signal: UInt8 = 1
                _ = Darwin.write(ready, &signal, 1)
            }
        )
        try Data("completed".utf8).write(
            to: URL(fileURLWithPath: completedPath),
            options: .withoutOverwriting
        )
    }

    func testCoordinatorProgressesTenEighteenTwentyFourWithOneCacheAndPublishes() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let native = CoordinatorNativeHarness(plans: [.noSubject, .ambiguity, .complete])
        let masks = CoordinatorMaskHarness()
        let coordinator = SubjectIsolationCoordinator(
            nativeOperation: native.run,
            maskAcquisition: masks.acquire
        )

        let outcome = try await coordinator.isolate(
            request: fixture.request(),
            onProgress: { _ in },
            onLog: { _, _ in }
        )

        guard case .completed(let output) = outcome else {
            return XCTFail("Expected published completion.")
        }
        XCTAssertEqual(
            output.url.resolvingSymlinksInPath(),
            fixture.paths.isolatedOutputURL.resolvingSymlinksInPath()
        )
        XCTAssertEqual(native.records.map(\.viewCount), [10, 18, 24])
        XCTAssertEqual(Set(native.records.map(\.analysisCacheURL)).count, 1)
        XCTAssertEqual(Set(native.records.map(\.outputURL)).count, 3)
        XCTAssertEqual(masks.batchSizes, [10, 8, 6])
        XCTAssertEqual(Set(masks.imageIdentities).count, 24)
        guard case .valid(let artifact, _) =
                SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("Expected the artifact store to own publication.")
        }
        XCTAssertEqual(artifact.masks.count, 24)
        XCTAssertEqual(artifact.sourcePlySHA256, fixture.publication.outputEvidence.sha256)
        XCTAssertEqual(artifact.trainingManifestSHA256, fixture.publication.trainingManifestSHA256)
        XCTAssertEqual(artifact.nativeExecutableSHA256, try GeometryArtifactStore.sha256(of: fixture.executable))
        XCTAssertEqual(artifact.visionRequestRevision, 1)
    }

    func testEarlySuccessStopsProgression() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let native = CoordinatorNativeHarness(plans: [.complete])
        let masks = CoordinatorMaskHarness()
        let unusedAnchor = SubjectAnchor(
            imageIdentity: "frame-0.png",
            instanceLabel: 1,
            normalizedX: 0.5,
            normalizedY: 0.5
        )

        let outcome = try await SubjectIsolationCoordinator(
            nativeOperation: native.run,
            maskAcquisition: masks.acquire
        ).isolate(
            request: fixture.request(anchor: unusedAnchor),
            onProgress: { _ in },
            onLog: { _, _ in }
        )

        guard case .completed = outcome else {
            return XCTFail("Expected completion.")
        }
        XCTAssertEqual(native.records.map(\.viewCount), [10])
        XCTAssertEqual(masks.batchSizes, [10])
        guard case .valid(let artifact, _) =
                SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("Expected published artifact.")
        }
        XCTAssertNil(artifact.subjectAnchor)
    }

    func testFinalAmbiguityBuildsUsableKeyframeMaskRequest() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let native = CoordinatorNativeHarness(plans: [.noSubject, .ambiguity, .ambiguity])
        let masks = CoordinatorMaskHarness()

        let outcome = try await SubjectIsolationCoordinator(
            nativeOperation: native.run,
            maskAcquisition: masks.acquire
        ).isolate(
            request: fixture.request(),
            onProgress: { _ in },
            onLog: { _, _ in }
        )

        guard case .ambiguity(let request) = outcome else {
            return XCTFail("Expected ambiguity.")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: request.keyframeImageURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: request.combinedInstanceLabelMaskURL.path
            )
        )
        XCTAssertEqual(request.pixelWidth, 4)
        XCTAssertEqual(request.pixelHeight, 4)
        XCTAssertEqual(request.candidates.first?.componentIdentity, "component-main")
        XCTAssertEqual(request.candidates.first?.instanceLabel, 1)
        XCTAssertEqual(request.candidates.first?.confidence, 0.9)
        XCTAssertNotEqual(SubjectIsolationArtifactStore.load(paths: fixture.paths), .invalid)
        guard case .noArtifact = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("Ambiguity must not publish.")
        }
    }

    func testFinalAmbiguityOnlyOffersCandidatesFromDisplayedKeyframe() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let native = CoordinatorNativeHarness(
            plans: [.noSubject, .ambiguity, .splitKeyframeAmbiguity]
        )

        let outcome = try await SubjectIsolationCoordinator(
            nativeOperation: native.run,
            maskAcquisition: CoordinatorMaskHarness().acquire
        ).isolate(
            request: fixture.request(),
            onProgress: { _ in },
            onLog: { _, _ in }
        )

        guard case .ambiguity(let request) = outcome else {
            return XCTFail("Expected ambiguity.")
        }
        XCTAssertEqual(request.keyframeImageURL.lastPathComponent, "frame-0.png")
        XCTAssertEqual(
            request.candidates.map(\.componentIdentity),
            ["component-main"]
        )
        XCTAssertEqual(request.candidates.map(\.instanceLabel), [1])
    }

    func testCancellingAmbiguityRetiresItsOwnedStagingExactlyOnce() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let native = CoordinatorNativeHarness(plans: [.noSubject, .ambiguity, .ambiguity])

        let outcome = try await SubjectIsolationCoordinator(
            nativeOperation: native.run,
            maskAcquisition: CoordinatorMaskHarness().acquire
        ).isolate(
            request: fixture.request(),
            onProgress: { _ in },
            onLog: { _, _ in }
        )

        guard case .ambiguity(let request) = outcome else {
            return XCTFail("Expected ambiguity.")
        }
        let ownedStaging = request.combinedInstanceLabelMaskURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownedStaging.path))

        try SubjectIsolationCoordinator.cancelPendingAmbiguity(
            projectPaths: fixture.paths
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedStaging.path))

        try SubjectIsolationCoordinator.cancelPendingAmbiguity(
            projectPaths: fixture.paths
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedStaging.path))
    }

    func testCancellingAmbiguityClearsOwnedImmutableRuntimeResidue() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let outcome = try await SubjectIsolationCoordinator(
            nativeOperation: CoordinatorNativeHarness(
                plans: [.noSubject, .ambiguity, .ambiguity]
            ).run,
            maskAcquisition: CoordinatorMaskHarness().acquire
        ).isolate(
            request: fixture.request(),
            onProgress: { _ in },
            onLog: { _, _ in }
        )
        guard case .ambiguity(let request) = outcome else {
            return XCTFail("Expected ambiguity.")
        }
        let ownedStaging = request.combinedInstanceLabelMaskURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runtime = ownedStaging.appendingPathComponent(
            ".native-runtime",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: runtime,
            withIntermediateDirectories: false
        )
        let immutableFile = runtime.appendingPathComponent("easysplat-train")
        try Data("crash-residue".utf8).write(
            to: immutableFile,
            options: .withoutOverwriting
        )
        XCTAssertEqual(Darwin.chflags(immutableFile.path, UInt32(UF_IMMUTABLE)), 0)
        XCTAssertEqual(Darwin.chflags(runtime.path, UInt32(UF_IMMUTABLE)), 0)
        defer {
            _ = Darwin.chflags(immutableFile.path, 0)
            _ = Darwin.chflags(runtime.path, 0)
        }

        try SubjectIsolationCoordinator.cancelPendingAmbiguity(
            projectPaths: fixture.paths
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedStaging.path))
    }

    func testCancellingAmbiguityCannotFollowAReplacedStagingParent() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let baselineStaging = try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.isolationStagingURL.path
        ).sorted()
        let native = CoordinatorNativeHarness(plans: [.noSubject, .ambiguity, .ambiguity])

        let outcome = try await SubjectIsolationCoordinator(
            nativeOperation: native.run,
            maskAcquisition: CoordinatorMaskHarness().acquire
        ).isolate(
            request: fixture.request(),
            onProgress: { _ in },
            onLog: { _, _ in }
        )
        guard case .ambiguity = outcome else {
            return XCTFail("Expected ambiguity.")
        }

        let stagingRoot = fixture.paths.isolationStagingURL
        let displacedRoot = fixture.paths.isolationURL.appendingPathComponent(
            ".displaced-staging",
            isDirectory: true
        )
        var foreignSentinel: URL?

        try SubjectIsolationCoordinator.cancelPendingAmbiguity(
            projectPaths: fixture.paths,
            beforeOwnedStagingRemoval: { retiredURL in
                try FileManager.default.moveItem(
                    at: stagingRoot,
                    to: displacedRoot
                )
                try FileManager.default.createDirectory(
                    at: retiredURL,
                    withIntermediateDirectories: true
                )
                let sentinel = retiredURL.appendingPathComponent("foreign.txt")
                try Data("foreign".utf8).write(to: sentinel)
                foreignSentinel = sentinel
            }
        )

        let sentinel = try XCTUnwrap(foreignSentinel)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("foreign".utf8))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: displacedRoot.path
            ).sorted(),
            baselineStaging
        )

        try SubjectIsolationCoordinator.cancelPendingAmbiguity(
            projectPaths: fixture.paths
        )
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("foreign".utf8))
    }

    func testRetirementPreservesAuthorityWhenStagingRootIsDisplacedBeforeOpen() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let outcome = try await SubjectIsolationCoordinator(
            nativeOperation: CoordinatorNativeHarness(
                plans: [.noSubject, .ambiguity, .ambiguity]
            ).run,
            maskAcquisition: CoordinatorMaskHarness().acquire
        ).isolate(
            request: fixture.request(),
            onProgress: { _ in },
            onLog: { _, _ in }
        )
        guard case .ambiguity(let choice) = outcome else {
            return XCTFail("Expected ambiguity.")
        }
        let ownedRun = choice.combinedInstanceLabelMaskURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let previewBytes = try Data(contentsOf: choice.combinedInstanceLabelMaskURL)
        let marker = fixture.paths.isolationURL.appendingPathComponent(
            ".ambiguity-owner-v1"
        )
        let markerBytes = try Data(contentsOf: marker)
        let stagingRoot = fixture.paths.isolationStagingURL
        let displacedRoot = fixture.paths.isolationURL.appendingPathComponent(
            ".displaced-before-staging-open",
            isDirectory: true
        )
        let injection = CoordinatorOneShot()

        XCTAssertThrowsError(
            try SubjectIsolationCoordinator.cancelPendingAmbiguity(
                projectPaths: fixture.paths,
                beforeOwnedStagingRemoval: { _ in },
                cleanupCheckpoint: { checkpoint in
                    guard checkpoint == .willOpenStagingRoot,
                          injection.claim() else { return }
                    try FileManager.default.moveItem(
                        at: stagingRoot,
                        to: displacedRoot
                    )
                    try FileManager.default.createDirectory(
                        at: stagingRoot,
                        withIntermediateDirectories: false,
                        attributes: [.posixPermissions: 0o700]
                    )
                }
            )
        )

        XCTAssertEqual(try Data(contentsOf: marker), markerBytes)
        let displacedRun = displacedRoot.appendingPathComponent(
            ownedRun.lastPathComponent,
            isDirectory: true
        )
        XCTAssertEqual(
            try Data(
                contentsOf: displacedRun.appendingPathComponent("masks/0000.png")
            ),
            previewBytes
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: stagingRoot.path
            ).isEmpty
        )
    }

    func testCancellingAmbiguityDoesNotDeleteAReplacedRetiredDirectory() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let native = CoordinatorNativeHarness(plans: [.noSubject, .ambiguity, .ambiguity])

        let outcome = try await SubjectIsolationCoordinator(
            nativeOperation: native.run,
            maskAcquisition: CoordinatorMaskHarness().acquire
        ).isolate(
            request: fixture.request(),
            onProgress: { _ in },
            onLog: { _, _ in }
        )
        guard case .ambiguity = outcome else {
            return XCTFail("Expected ambiguity.")
        }

        var foreignSentinel: URL?
        var displacedOwnedDirectory: URL?
        XCTAssertThrowsError(
            try SubjectIsolationCoordinator.cancelPendingAmbiguity(
                projectPaths: fixture.paths,
                beforeOwnedStagingRemoval: { retiredURL in
                    let displaced = retiredURL.deletingLastPathComponent()
                        .appendingPathComponent(
                            ".displaced-owned-run",
                            isDirectory: true
                        )
                    try FileManager.default.moveItem(
                        at: retiredURL,
                        to: displaced
                    )
                    try FileManager.default.createDirectory(
                        at: retiredURL,
                        withIntermediateDirectories: false
                    )
                    let sentinel = retiredURL.appendingPathComponent("foreign.txt")
                    try Data("foreign".utf8).write(to: sentinel)
                    displacedOwnedDirectory = displaced
                    foreignSentinel = sentinel
                }
            )
        )

        let sentinel = try XCTUnwrap(foreignSentinel)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("foreign".utf8))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: try XCTUnwrap(displacedOwnedDirectory).path
            ),
            []
        )
    }

    func testSuccessfulRetrySupersedesPriorAmbiguityStaging() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let baselineStaging = try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.isolationStagingURL.path
        ).sorted()
        let firstNative = CoordinatorNativeHarness(
            plans: [.noSubject, .ambiguity, .ambiguity]
        )
        let firstOutcome = try await SubjectIsolationCoordinator(
            nativeOperation: firstNative.run,
            maskAcquisition: CoordinatorMaskHarness().acquire
        ).isolate(
            request: fixture.request(),
            onProgress: { _ in },
            onLog: { _, _ in }
        )
        guard case .ambiguity(let choice) = firstOutcome else {
            return XCTFail("Expected ambiguity.")
        }
        let priorStaging = choice.combinedInstanceLabelMaskURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: priorStaging.path))

        let retryNative = CoordinatorNativeHarness(plans: [.complete])
        let retryOutcome = try await SubjectIsolationCoordinator(
            nativeOperation: retryNative.run,
            maskAcquisition: CoordinatorMaskHarness().acquire
        ).isolate(
            request: fixture.request(anchor: SubjectAnchor(
                imageIdentity: "frame-0.png",
                instanceLabel: 1,
                normalizedX: 0.5,
                normalizedY: 0.5
            )),
            onProgress: { _ in },
            onLog: { _, _ in }
        )

        guard case .completed = retryOutcome else {
            return XCTFail("Expected the retry to publish.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: priorStaging.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.paths.isolationStagingURL.path
            ).sorted(),
            baselineStaging
        )
    }

    func testFinalNoSubjectAndHeldOutRejectionPublishNothing() async throws {
        for finalPlan in [CoordinatorNativeHarness.Plan.noSubject, .heldOutRejected] {
            let fixture = try CoordinatorFixture()
            defer { fixture.cleanup() }
            let native = CoordinatorNativeHarness(
                plans: [.noSubject, .ambiguity, finalPlan]
            )
            let coordinator = SubjectIsolationCoordinator(
                nativeOperation: native.run,
                maskAcquisition: CoordinatorMaskHarness().acquire
            )

            do {
                let outcome = try await coordinator.isolate(
                    request: fixture.request(),
                    onProgress: { _ in },
                    onLog: { _, _ in }
                )
                XCTAssertEqual(finalPlan, .noSubject)
                XCTAssertEqual(outcome, .noSubject)
            } catch let error as SubjectIsolationCoordinatorError {
                XCTAssertEqual(finalPlan, .heldOutRejected)
                XCTAssertEqual(error, .heldOutRejected)
            }
            guard case .noArtifact = SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
                return XCTFail("Rejected isolation must not publish.")
            }
        }
    }

    func testAnchorRetryReusesFinalMasksAndCacheAndCanPublish() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let native = CoordinatorNativeHarness(
            plans: [.noSubject, .ambiguity, .ambiguity, .complete]
        )
        let masks = CoordinatorMaskHarness()
        let anchor = SubjectAnchor(
            imageIdentity: "frame-0.png",
            instanceLabel: 1,
            normalizedX: 0.5,
            normalizedY: 0.5
        )

        let outcome = try await SubjectIsolationCoordinator(
            nativeOperation: native.run,
            maskAcquisition: masks.acquire
        ).isolate(
            request: fixture.request(anchor: anchor),
            onProgress: { _ in },
            onLog: { _, _ in }
        )

        guard case .completed = outcome else {
            return XCTFail("Expected anchored completion.")
        }
        XCTAssertEqual(native.records.map(\.viewCount), [10, 18, 24, 24])
        XCTAssertNil(native.records[2].anchor)
        XCTAssertEqual(native.records[3].anchor, anchor)
        XCTAssertEqual(native.records[2].analysisCacheURL, native.records[3].analysisCacheURL)
        XCTAssertEqual(native.records[2].maskManifestURL, native.records[3].maskManifestURL)
        XCTAssertEqual(masks.batchSizes, [10, 8, 6])
        guard case .valid(let artifact, _) =
                SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("Expected anchored artifact.")
        }
        XCTAssertEqual(artifact.subjectAnchor, anchor)
    }

    func testCancellationPreservesCanonicalAndPreviousSubjectBytes() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        try fixture.base.rebuildStaging(vertexCount: 1, maskValue: 1)
        let priorArtifact = try fixture.base.makeArtifact()
        _ = try SubjectIsolationArtifactStore.publish(
            priorArtifact,
            stagedOutputURL: fixture.base.stagedOutputURL,
            stagedMasksURL: fixture.base.stagedMasksURL,
            paths: fixture.paths
        )
        let canonical = try Data(contentsOf: fixture.paths.outputSplatURL)
        let priorOutput = try Data(contentsOf: fixture.paths.isolatedOutputURL)
        let priorManifest = try Data(contentsOf: fixture.paths.isolationManifestURL)
        let native = CoordinatorNativeHarness(plans: [.cancel])

        do {
            _ = try await SubjectIsolationCoordinator(
                nativeOperation: native.run,
                maskAcquisition: CoordinatorMaskHarness().acquire
            ).isolate(
                request: fixture.request(),
                onProgress: { _ in },
                onLog: { _, _ in }
            )
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            XCTAssertEqual(try Data(contentsOf: fixture.paths.outputSplatURL), canonical)
            XCTAssertEqual(try Data(contentsOf: fixture.paths.isolatedOutputURL), priorOutput)
            XCTAssertEqual(try Data(contentsOf: fixture.paths.isolationManifestURL), priorManifest)
        }
    }

    func testSourceExecutableReplacementAfterPrivateBindingCannotInfluenceRun() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let originalDigest = try GeometryArtifactStore.sha256(of: fixture.executable)
        let executableURL = fixture.executable
        let native = CoordinatorNativeHarness(plans: [.complete])
        let replacingOperation: SubjectIsolationNativeOperation = {
            request, onProgress, onLog in
            try Data("replacement-native".utf8).write(
                to: executableURL,
                options: .atomic
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executableURL.path
            )
            return try await native.run(
                request: request,
                onProgress: onProgress,
                onLog: onLog
            )
        }

        let outcome = try await SubjectIsolationCoordinator(
            nativeOperation: replacingOperation,
            maskAcquisition: CoordinatorMaskHarness().acquire
        ).isolate(
            request: fixture.request(),
            onProgress: { _ in },
            onLog: { _, _ in }
        )
        guard case .completed = outcome else {
            return XCTFail("Expected the descriptor-bound private runtime to complete.")
        }

        XCTAssertNotEqual(
            try GeometryArtifactStore.sha256(of: fixture.executable),
            originalDigest
        )
        guard case .valid(let artifact, _) =
                SubjectIsolationArtifactStore.load(paths: fixture.paths) else {
            return XCTFail("Expected a publication bound to the original private runtime.")
        }
        XCTAssertEqual(artifact.nativeExecutableSHA256, originalDigest)
    }

    func testTransientExecutableAndMetallibSwapCannotInfluencePublishedSubject() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let executableBytes = try Data(contentsOf: fixture.executable)
        let metallibBytes = try Data(contentsOf: fixture.metallib)
        let native = TransientNativeRuntimeSwapHarness(
            executableURL: fixture.executable,
            metallibURL: fixture.metallib
        )

        let outcome = try await SubjectIsolationCoordinator(
            nativeOperation: native.run,
            maskAcquisition: CoordinatorMaskHarness().acquire
        ).isolate(
            request: fixture.request(),
            onProgress: { _ in },
            onLog: { _, _ in }
        )

        guard case .completed = outcome else {
            return XCTFail("The descriptor-bound original runtime should complete.")
        }
        XCTAssertEqual(native.observedExecutableBytes, executableBytes)
        XCTAssertEqual(native.observedMetallibBytes, metallibBytes)
        XCTAssertNotEqual(native.observedExecutableBytes, native.replacementExecutableBytes)
        XCTAssertNotEqual(native.observedMetallibBytes, native.replacementMetallibBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.executable), executableBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.metallib), metallibBytes)
    }

    func testTransientPrivateRuntimeSwapRestoredBeforePostflightCannotPublish() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let executableBytes = try Data(contentsOf: fixture.executable)
        let metallibBytes = try Data(contentsOf: fixture.metallib)
        let native = TransientPrivateNativeRuntimeSwapHarness()

        do {
            _ = try await SubjectIsolationCoordinator(
                nativeOperation: native.run,
                maskAcquisition: CoordinatorMaskHarness().acquire
            ).isolate(
                request: fixture.request(),
                onProgress: { _ in },
                onLog: { _, _ in }
            )
            XCTFail("A transient private-runtime swap must fail postflight validation.")
        } catch let error as SubjectIsolationCoordinatorError {
            XCTAssertEqual(error, .invalidProject)
        }

        XCTAssertEqual(
            native.observedExecutableBytes,
            executableBytes
        )
        XCTAssertEqual(native.observedMetallibBytes, metallibBytes)
        XCTAssertNotEqual(
            native.observedExecutableBytes,
            native.replacementExecutableBytes
        )
        XCTAssertNotEqual(native.observedMetallibBytes, native.replacementMetallibBytes)
        guard case .noArtifact = SubjectIsolationArtifactStore.load(
            paths: fixture.paths
        ) else {
            return XCTFail("Transient replacement bytes must not publish a subject.")
        }
    }

    func testTransientPrivateRuntimeAncestorSwapInvokesOnlyBoundRuntimeBytes() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let executableBytes = try Data(contentsOf: fixture.executable)
        let metallibBytes = try Data(contentsOf: fixture.metallib)
        let native = TransientPrivateNativeAncestorSwapHarness()

        let outcome = try await SubjectIsolationCoordinator(
            nativeOperation: native.run,
            maskAcquisition: CoordinatorMaskHarness().acquire
        ).isolate(
            request: fixture.request(),
            onProgress: { _ in },
            onLog: { _, _ in }
        )

        guard case .completed = outcome else {
            return XCTFail("The descriptor-bound private runtime should complete.")
        }
        XCTAssertEqual(native.observedExecutableBytes, executableBytes)
        XCTAssertEqual(native.observedMetallibBytes, metallibBytes)
        XCTAssertNotEqual(
            native.observedExecutableBytes,
            native.replacementExecutableBytes
        )
        XCTAssertNotEqual(native.observedMetallibBytes, native.replacementMetallibBytes)
    }

    func testRealSubprocessExecutesAndReadsRuntimeThroughExactVolumeURLs() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let originalMetallib = Data("original-metallib-payload".utf8)
        try originalMetallib.write(to: fixture.metallib, options: .atomic)
        try Data(
            "#!/bin/sh\nprintf ORIGINAL:\n/bin/cat \"$1\"\n".utf8
        ).write(to: fixture.executable, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fixture.executable.path
        )
        let native = RealSubprocessPrivateRuntimeHarness()

        let outcome = try await SubjectIsolationCoordinator(
            nativeOperation: native.run,
            maskAcquisition: CoordinatorMaskHarness().acquire
        ).isolate(
            request: fixture.request(),
            onProgress: { _ in },
            onLog: { _, _ in }
        )

        guard case .completed = outcome else {
            return XCTFail("Expected the exact private runtime to complete.")
        }
        XCTAssertTrue(native.executablePath.hasPrefix("/.vol/"))
        XCTAssertTrue(native.metallibPath.hasPrefix("/.vol/"))
        XCTAssertEqual(
            native.standardOutput,
            Data("ORIGINAL:".utf8) + originalMetallib
        )
    }

    func testCancelledNativeFailureClearsAllImmutablePrivateRuntimeStaging() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let baseline = try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.isolationStagingURL.path
        )
        let operation: SubjectIsolationNativeOperation = { _, _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }

        do {
            _ = try await SubjectIsolationCoordinator(
                nativeOperation: operation,
                maskAcquisition: CoordinatorMaskHarness().acquire
            ).isolate(
                request: fixture.request(),
                onProgress: { _ in },
                onLog: { _, _ in }
            )
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: fixture.paths.isolationStagingURL.path
                ),
                baseline
            )
        }
    }

    func testFailedIsolationCannotFollowReplacedStagingParent() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let stagingRoot = fixture.paths.isolationStagingURL
        let displacedRoot = fixture.paths.isolationURL.appendingPathComponent(
            ".failed-run-displaced-staging",
            isDirectory: true
        )
        let externalRoot = fixture.base.root.appendingPathComponent(
            "foreign-staging-target",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: stagingRoot)
            if FileManager.default.fileExists(atPath: displacedRoot.path) {
                try? FileManager.default.moveItem(at: displacedRoot, to: stagingRoot)
            }
            try? FileManager.default.removeItem(at: externalRoot)
        }

        let maskAcquisition: SubjectIsolationMaskAcquisition = {
            _, masksDirectory, _, _ in
            let runDirectory = masksDirectory.deletingLastPathComponent()
            try FileManager.default.moveItem(at: stagingRoot, to: displacedRoot)
            let foreignRun = externalRoot.appendingPathComponent(
                runDirectory.lastPathComponent,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: foreignRun,
                withIntermediateDirectories: true
            )
            try Data("foreign".utf8).write(
                to: foreignRun.appendingPathComponent("sentinel.txt")
            )
            try FileManager.default.createSymbolicLink(
                at: stagingRoot,
                withDestinationURL: externalRoot
            )
            throw CoordinatorProbeError.expectedFailure
        }

        do {
            _ = try await SubjectIsolationCoordinator(
                nativeOperation: CoordinatorNativeHarness(plans: [.complete]).run,
                maskAcquisition: maskAcquisition
            ).isolate(
                request: fixture.request(),
                onProgress: { _ in },
                onLog: { _, _ in }
            )
            XCTFail("Expected the injected mask failure.")
        } catch CoordinatorProbeError.expectedFailure {
            let foreignRuns = try FileManager.default.contentsOfDirectory(
                at: externalRoot,
                includingPropertiesForKeys: nil
            )
            XCTAssertEqual(foreignRuns.count, 1)
            XCTAssertEqual(
                try Data(contentsOf: foreignRuns[0].appendingPathComponent("sentinel.txt")),
                Data("foreign".utf8)
            )
        }
    }

    func testRuntimeBindingFailureRemovesOwnedStaging() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        try Data().write(to: fixture.metallib)

        do {
            _ = try await SubjectIsolationCoordinator(
                nativeOperation: CoordinatorNativeHarness(plans: [.complete]).run,
                maskAcquisition: CoordinatorMaskHarness().acquire
            ).isolate(
                request: fixture.request(),
                onProgress: { _ in },
                onLog: { _, _ in }
            )
            XCTFail("Expected invalid native runtime input to fail closed.")
        } catch let error as SubjectIsolationCoordinatorError {
            XCTAssertEqual(error, .invalidProject)
        }

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.paths.isolationStagingURL.path
            ),
            []
        )
    }

    func testSuccessfulAndNoSubjectResultsReportOwnedStagingCleanupFailure() async throws {
        for plans in [
            [CoordinatorNativeHarness.Plan.complete],
            [.noSubject, .noSubject, .noSubject],
        ] {
            try await withCoordinatorFixture { fixture in
                let native = CoordinatorNativeHarness(plans: plans)
                let injected = CoordinatorOneShot()
                let operation: SubjectIsolationNativeOperation = {
                    request, onProgress, onLog in
                    if injected.claim() {
                        let blocker = request.outputURL.deletingLastPathComponent()
                            .appendingPathComponent("cleanup-blocker.fifo")
                        guard Darwin.mkfifo(blocker.path, mode_t(0o600)) == 0 else {
                            throw NSError(
                                domain: NSPOSIXErrorDomain,
                                code: Int(errno)
                            )
                        }
                    }
                    return try await native.run(
                        request: request,
                        onProgress: onProgress,
                        onLog: onLog
                    )
                }

                do {
                    _ = try await SubjectIsolationCoordinator(
                        nativeOperation: operation,
                        maskAcquisition: CoordinatorMaskHarness().acquire
                    ).isolate(
                        request: fixture.request(),
                        onProgress: { _ in },
                        onLog: { _, _ in }
                    )
                    XCTFail("A normal result must not hide cleanup failure.")
                } catch let error as SubjectIsolationCleanupFailure {
                    XCTAssertNil(error.primaryFailureSummary)
                    XCTAssertFalse(error.cleanupFailureSummary.isEmpty)
                    XCTAssertLessThanOrEqual(
                        error.cleanupFailureSummary.utf8.count,
                        SubjectIsolationCleanupFailure.maximumSummaryByteCount
                    )
                }

                XCTAssertEqual(
                    try FileManager.default.contentsOfDirectory(
                        atPath: fixture.paths.isolationStagingURL.path
                    ).filter { !$0.hasPrefix(".") }.count,
                    1
                )
            }
        }
    }

    func testProcessingAndCleanupFailurePreservesBothBoundedCauses() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let operation: SubjectIsolationNativeOperation = { request, _, _ in
            let blocker = request.outputURL.deletingLastPathComponent()
                .appendingPathComponent("cleanup-blocker.fifo")
            guard Darwin.mkfifo(blocker.path, mode_t(0o600)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            throw CoordinatorProbeError.expectedFailure
        }

        do {
            _ = try await SubjectIsolationCoordinator(
                nativeOperation: operation,
                maskAcquisition: CoordinatorMaskHarness().acquire
            ).isolate(
                request: fixture.request(),
                onProgress: { _ in },
                onLog: { _, _ in }
            )
            XCTFail("Expected processing plus cleanup failure.")
        } catch let error as SubjectIsolationCleanupFailure {
            XCTAssertTrue(
                try XCTUnwrap(error.primaryFailureSummary)
                    .contains("expectedFailure")
            )
            XCTAssertFalse(error.cleanupFailureSummary.isEmpty)
            XCTAssertLessThanOrEqual(
                error.primaryFailureSummary?.utf8.count ?? 0,
                SubjectIsolationCleanupFailure.maximumSummaryByteCount
            )
            XCTAssertLessThanOrEqual(
                error.cleanupFailureSummary.utf8.count,
                SubjectIsolationCleanupFailure.maximumSummaryByteCount
            )
        }
    }

    func testCrossProcessRetirementCannotInvalidateClaimBeforeReturn() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let claimPaused = DispatchSemaphore(value: 0)
        let releaseClaim = DispatchSemaphore(value: 0)
        let coordinator = SubjectIsolationCoordinator(
            nativeOperation: CoordinatorNativeHarness(
                plans: [.noSubject, .ambiguity, .ambiguity]
            ).run,
            maskAcquisition: CoordinatorMaskHarness().acquire,
            ambiguityLeaseCheckpoint: { checkpoint, _ in
                guard checkpoint == .claimDurable else { return }
                claimPaused.signal()
                guard releaseClaim.wait(timeout: .now() + 20) == .success else {
                    throw CoordinatorProbeError.timeout
                }
            }
        )
        let isolationTask = Task {
            try await coordinator.isolate(
                request: fixture.request(),
                onProgress: { _ in },
                onLog: { _, _ in }
            )
        }
        defer {
            releaseClaim.signal()
            isolationTask.cancel()
        }

        guard await waitForSemaphore(claimPaused, timeout: 10) else {
            return XCTFail("The ambiguity claim never reached its durable pause.")
        }
        let ownedRuns = try FileManager.default.contentsOfDirectory(
            at: fixture.paths.isolationStagingURL,
            includingPropertiesForKeys: nil
        ).filter { !$0.lastPathComponent.hasPrefix(".") }
        guard ownedRuns.count == 1 else {
            return XCTFail("Expected exactly one claimed staging run, got \(ownedRuns).")
        }
        let ownedRun = ownedRuns[0]
        let previewMask = ownedRun.appendingPathComponent("masks/0000.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: previewMask.path))

        let attempted = fixture.base.root.appendingPathComponent("retire-attempted")
        let ready = fixture.base.root.appendingPathComponent("retire-ready.fifo")
        let completed = fixture.base.root.appendingPathComponent("retire-completed")
        XCTAssertEqual(Darwin.mkfifo(ready.path, mode_t(0o600)), 0)
        let readyDescriptor = Darwin.open(
            ready.path,
            O_RDWR | O_NONBLOCK | O_CLOEXEC
        )
        guard readyDescriptor >= 0 else {
            return XCTFail("Could not open the retirement readiness pipe.")
        }
        defer { Darwin.close(readyDescriptor) }
        let child = try runCrossProcessRetirementHelper(
            projectRoot: fixture.paths.root,
            attemptedURL: attempted,
            readyURL: ready,
            completedURL: completed
        )
        defer {
            if child.isRunning { child.terminate() }
        }
        guard await waitForFIFOByte(readyDescriptor, timeout: 10) else {
            return XCTFail("The retirement helper never attempted cancellation.")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: attempted.path))
        XCTAssertTrue(child.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: completed.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: previewMask.path),
            "Cross-process retirement must wait until the claim returns."
        )

        releaseClaim.signal()
        guard case .ambiguity = try await isolationTask.value else {
            return XCTFail("Expected the paused claim to return its ambiguity.")
        }
        guard await waitForProcess(child, timeout: 20) else {
            child.terminate()
            _ = await waitForProcess(child, timeout: 5)
            return XCTFail("The cross-process retirement helper did not terminate.")
        }
        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: completed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ownedRun.path))
    }

    func testContendedLifecycleLockHonorsTaskCancellation() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let claimPaused = DispatchSemaphore(value: 0)
        let releaseClaim = DispatchSemaphore(value: 0)
        let firstCoordinator = SubjectIsolationCoordinator(
            nativeOperation: CoordinatorNativeHarness(
                plans: [.noSubject, .ambiguity, .ambiguity]
            ).run,
            maskAcquisition: CoordinatorMaskHarness().acquire,
            ambiguityLeaseCheckpoint: { checkpoint, _ in
                guard checkpoint == .claimDurable else { return }
                claimPaused.signal()
                guard releaseClaim.wait(timeout: .now() + 20) == .success else {
                    throw CoordinatorProbeError.timeout
                }
            }
        )
        let firstTask = Task {
            try await firstCoordinator.isolate(
                request: fixture.request(),
                onProgress: { _ in },
                onLog: { _, _ in }
            )
        }
        defer {
            releaseClaim.signal()
            firstTask.cancel()
        }

        guard await waitForSemaphore(claimPaused, timeout: 10) else {
            firstTask.cancel()
            releaseClaim.signal()
            _ = try? await firstTask.value
            return XCTFail("The first coordinator never acquired its lifecycle lock.")
        }

        let contentionObserved = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        let secondResult = CoordinatorCancellationResultCapture()
        let secondCoordinator = SubjectIsolationCoordinator(
            nativeOperation: CoordinatorNativeHarness(plans: [.complete]).run,
            maskAcquisition: CoordinatorMaskHarness().acquire,
            ambiguityLockContention: {
                contentionObserved.signal()
            }
        )
        let secondTask = Task {
            defer { secondFinished.signal() }
            do {
                _ = try await secondCoordinator.isolate(
                    request: fixture.request(),
                    onProgress: { _ in },
                    onLog: { _, _ in }
                )
                secondResult.record(.completed)
            } catch is CancellationError {
                secondResult.record(.cancelled)
            } catch {
                secondResult.record(.failed(String(describing: error)))
            }
        }
        defer { secondTask.cancel() }

        guard await waitForSemaphore(contentionObserved, timeout: 10) else {
            secondTask.cancel()
            releaseClaim.signal()
            _ = await waitForSemaphore(secondFinished, timeout: 5)
            _ = try? await firstTask.value
            return XCTFail("The second coordinator never contended on the real lock.")
        }
        secondTask.cancel()
        guard await waitForSemaphore(secondFinished, timeout: 2) else {
            releaseClaim.signal()
            _ = await waitForSemaphore(secondFinished, timeout: 5)
            _ = try? await firstTask.value
            return XCTFail("Lock contention did not respond to task cancellation.")
        }
        XCTAssertEqual(secondResult.value, .cancelled)
        let isolationNames = try FileManager.default.contentsOfDirectory(
            atPath: fixture.paths.isolationURL.path
        )
        XCTAssertTrue(isolationNames.contains(".ambiguity-owner-v1"))
        XCTAssertFalse(isolationNames.contains {
            $0.hasPrefix(".retired-ambiguity-")
        })
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.paths.isolationStagingURL.path
            ).filter { !$0.hasPrefix(".") }.count,
            1
        )

        releaseClaim.signal()
        guard case .ambiguity = try await firstTask.value else {
            return XCTFail("Expected the first ambiguity claim to finish.")
        }
        try SubjectIsolationCoordinator.cancelPendingAmbiguity(
            projectPaths: fixture.paths
        )
    }

    func testLegacyOFDOnlyHolderRemainsCompatibleWithoutMixedLockDeadlock() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        try fixture.paths.ensureIsolationDirectories()
        let lockURL = fixture.paths.isolationURL.appendingPathComponent(
            ".ambiguity-lifecycle.lock"
        )
        try Data().write(to: lockURL, options: .withoutOverwriting)
        guard Darwin.chmod(lockURL.path, mode_t(0o600)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        let readyURL = fixture.base.root.appendingPathComponent(
            "legacy-ofd-ready.fifo"
        )
        let releaseURL = fixture.base.root.appendingPathComponent(
            "legacy-ofd-release.fifo"
        )
        XCTAssertEqual(Darwin.mkfifo(readyURL.path, mode_t(0o600)), 0)
        XCTAssertEqual(Darwin.mkfifo(releaseURL.path, mode_t(0o600)), 0)
        let readyDescriptor = Darwin.open(
            readyURL.path,
            O_RDWR | O_NONBLOCK | O_CLOEXEC
        )
        let releaseDescriptor = Darwin.open(
            releaseURL.path,
            O_RDWR | O_NONBLOCK | O_CLOEXEC
        )
        guard readyDescriptor >= 0, releaseDescriptor >= 0 else {
            if readyDescriptor >= 0 { Darwin.close(readyDescriptor) }
            if releaseDescriptor >= 0 { Darwin.close(releaseDescriptor) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer {
            Darwin.close(releaseDescriptor)
            Darwin.close(readyDescriptor)
        }

        let child = try runLegacyOFDLockHelper(
            lockURL: lockURL,
            readyURL: readyURL,
            releaseURL: releaseURL
        )
        defer {
            if child.isRunning {
                var release: UInt8 = 1
                _ = Darwin.write(releaseDescriptor, &release, 1)
                child.terminate()
            }
        }
        guard await waitForFIFOByte(readyDescriptor, timeout: 10) else {
            return XCTFail("The legacy-only OFD helper never acquired its lock.")
        }

        let firstState = CoordinatorLockRaceCapture()
        let firstContended = DispatchSemaphore(value: 0)
        let firstTask = Task {
            defer { firstState.recordCompletion() }
            try SubjectIsolationCoordinator.cancelPendingAmbiguity(
                projectPaths: fixture.paths,
                beforeOwnedStagingRemoval: { _ in },
                onLockContention: {
                    firstState.recordContention()
                    firstContended.signal()
                }
            )
        }
        defer { firstTask.cancel() }
        guard await waitForSemaphore(firstContended, timeout: 10) else {
            return XCTFail("The new lock never contended on the legacy OFD lock.")
        }
        XCTAssertTrue(firstState.didContend)
        XCTAssertFalse(firstState.didComplete)

        let secondState = CoordinatorLockRaceCapture()
        let secondContended = DispatchSemaphore(value: 0)
        let secondTask = Task {
            defer { secondState.recordCompletion() }
            try SubjectIsolationCoordinator.cancelPendingAmbiguity(
                projectPaths: fixture.paths,
                beforeOwnedStagingRemoval: { _ in },
                onLockContention: {
                    secondState.recordContention()
                    secondContended.signal()
                }
            )
        }
        defer { secondTask.cancel() }
        guard await waitForSemaphore(secondContended, timeout: 10) else {
            return XCTFail("The second new lock never contended on the directory flock.")
        }
        XCTAssertTrue(secondState.didContend)
        XCTAssertFalse(secondState.didComplete)

        var release: UInt8 = 1
        XCTAssertEqual(Darwin.write(releaseDescriptor, &release, 1), 1)
        try await firstTask.value
        try await secondTask.value
        guard await waitForProcess(child, timeout: 10) else {
            child.terminate()
            return XCTFail("The legacy-only OFD helper did not terminate.")
        }
        XCTAssertEqual(child.terminationStatus, 0)
        XCTAssertTrue(firstState.didComplete)
        XCTAssertTrue(secondState.didComplete)
    }

    func testLifecycleLockRejectsForeignHardLinkWithoutChangingPermissions() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        try fixture.paths.ensureIsolationDirectories()
        let foreign = fixture.base.root.appendingPathComponent("foreign-lock-source")
        try Data("foreign".utf8).write(to: foreign, options: .withoutOverwriting)
        guard Darwin.chmod(foreign.path, mode_t(0o644)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let lockURL = fixture.paths.isolationURL.appendingPathComponent(
            ".ambiguity-lifecycle.lock"
        )
        let linkResult = foreign.path.withCString { source in
            lockURL.path.withCString { destination in
                Darwin.link(source, destination)
            }
        }
        XCTAssertEqual(linkResult, 0)

        XCTAssertThrowsError(
            try SubjectIsolationCoordinator.cancelPendingAmbiguity(
                projectPaths: fixture.paths
            )
        )
        var status = stat()
        let statResult = foreign.path.withCString {
            Darwin.lstat($0, &status)
        }
        XCTAssertEqual(statResult, 0)
        XCTAssertEqual(UInt32(status.st_mode) & 0o7777, 0o644)
        XCTAssertEqual(try Data(contentsOf: foreign), Data("foreign".utf8))
    }

    func testReplacingLifecycleLockPathCannotSplitActiveExclusion() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let claimPaused = DispatchSemaphore(value: 0)
        let releaseClaim = DispatchSemaphore(value: 0)
        let firstTask = Task {
            try await SubjectIsolationCoordinator(
                nativeOperation: CoordinatorNativeHarness(
                    plans: [.noSubject, .ambiguity, .ambiguity]
                ).run,
                maskAcquisition: CoordinatorMaskHarness().acquire,
                ambiguityLeaseCheckpoint: { checkpoint, _ in
                    guard checkpoint == .claimDurable else { return }
                    claimPaused.signal()
                    guard releaseClaim.wait(timeout: .now() + 20) == .success else {
                        throw CoordinatorProbeError.timeout
                    }
                }
            ).isolate(
                request: fixture.request(),
                onProgress: { _ in },
                onLog: { _, _ in }
            )
        }
        defer {
            releaseClaim.signal()
            firstTask.cancel()
        }
        guard await waitForSemaphore(claimPaused, timeout: 10) else {
            return XCTFail("The first ambiguity claim never acquired exclusion.")
        }

        let lockURL = fixture.paths.isolationURL.appendingPathComponent(
            ".ambiguity-lifecycle.lock"
        )
        let displacedLockURL = fixture.paths.isolationURL.appendingPathComponent(
            ".displaced-ambiguity-lifecycle.lock"
        )
        try FileManager.default.moveItem(at: lockURL, to: displacedLockURL)
        try Data().write(to: lockURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: lockURL.path
        )

        let contention = CoordinatorLockRaceCapture()
        let observed = DispatchSemaphore(value: 0)
        let secondTask = Task {
            defer {
                contention.recordCompletion()
                observed.signal()
            }
            try SubjectIsolationCoordinator.cancelPendingAmbiguity(
                projectPaths: fixture.paths,
                beforeOwnedStagingRemoval: { _ in },
                onLockContention: {
                    contention.recordContention()
                    observed.signal()
                }
            )
        }
        defer { secondTask.cancel() }

        guard await waitForSemaphore(observed, timeout: 10) else {
            return XCTFail("The competing retirement neither contended nor completed.")
        }
        XCTAssertTrue(contention.didContend)
        XCTAssertFalse(contention.didComplete)

        releaseClaim.signal()
        guard case .ambiguity = try await firstTask.value else {
            return XCTFail("Expected the first ambiguity claim to finish.")
        }
        try await secondTask.value
        XCTAssertTrue(contention.didComplete)
    }

    func testRetirementQuarantinesExactFileBeforeDeletionAndPreservesReplacement() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let outcome = try await SubjectIsolationCoordinator(
            nativeOperation: CoordinatorNativeHarness(
                plans: [.noSubject, .ambiguity, .ambiguity]
            ).run,
            maskAcquisition: CoordinatorMaskHarness().acquire
        ).isolate(
            request: fixture.request(),
            onProgress: { _ in },
            onLog: { _, _ in }
        )
        guard case .ambiguity(let choice) = outcome else {
            return XCTFail("Expected ambiguity.")
        }
        let ownedRun = choice.combinedInstanceLabelMaskURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let target = ownedRun.appendingPathComponent("race-target.txt")
        try Data("owned".utf8).write(to: target, options: .withoutOverwriting)
        let retiredCapture = CoordinatorURLCapture()
        let injection = CoordinatorOneShot()

        XCTAssertThrowsError(
            try SubjectIsolationCoordinator.cancelPendingAmbiguity(
                projectPaths: fixture.paths,
                beforeOwnedStagingRemoval: { retiredCapture.record($0) },
                cleanupCheckpoint: { checkpoint in
                    guard case .willQuarantine(let relativePath) = checkpoint,
                          relativePath == "race-target.txt",
                          injection.claim() else { return }
                    let retired = try retiredCapture.value()
                    let retiredTarget = retired.appendingPathComponent(
                        "race-target.txt"
                    )
                    let displaced = retired.appendingPathComponent("owned-displaced.txt")
                    try FileManager.default.moveItem(at: retiredTarget, to: displaced)
                    try Data("foreign".utf8).write(
                        to: retiredTarget,
                        options: .withoutOverwriting
                    )
                }
            )
        )

        let retired = try retiredCapture.value()
        XCTAssertEqual(
            try Data(contentsOf: retired.appendingPathComponent("race-target.txt")),
            Data("foreign".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: retired.appendingPathComponent("owned-displaced.txt")),
            Data("owned".utf8)
        )
    }

    func testRetirementPreservesForeignReplacementSwappedAfterQuarantine() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let outcome = try await SubjectIsolationCoordinator(
            nativeOperation: CoordinatorNativeHarness(
                plans: [.noSubject, .ambiguity, .ambiguity]
            ).run,
            maskAcquisition: CoordinatorMaskHarness().acquire
        ).isolate(
            request: fixture.request(),
            onProgress: { _ in },
            onLog: { _, _ in }
        )
        guard case .ambiguity(let choice) = outcome else {
            return XCTFail("Expected ambiguity.")
        }
        let ownedRun = choice.combinedInstanceLabelMaskURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let target = ownedRun.appendingPathComponent("post-quarantine-race.txt")
        try Data("owned".utf8).write(to: target, options: .withoutOverwriting)
        let retiredCapture = CoordinatorURLCapture()
        let racedURLs = CoordinatorQuarantineRaceCapture()
        let injection = CoordinatorOneShot()

        XCTAssertThrowsError(
            try SubjectIsolationCoordinator.cancelPendingAmbiguity(
                projectPaths: fixture.paths,
                beforeOwnedStagingRemoval: { retiredCapture.record($0) },
                cleanupCheckpoint: { checkpoint in
                    guard case .willUnlinkQuarantined(
                        let relativePath,
                        let quarantineLeaf
                    ) = checkpoint,
                    relativePath == "post-quarantine-race.txt",
                    injection.claim() else { return }
                    let retired = try retiredCapture.value()
                    let quarantine = retired.appendingPathComponent(quarantineLeaf)
                    let displaced = retired.appendingPathComponent(
                        "owned-post-quarantine-displaced.txt"
                    )
                    try FileManager.default.moveItem(at: quarantine, to: displaced)
                    try Data("foreign".utf8).write(
                        to: quarantine,
                        options: .withoutOverwriting
                    )
                    racedURLs.record(
                        quarantineURL: quarantine,
                        displacedURL: displaced
                    )
                }
            )
        )

        let urls = try racedURLs.urls()
        XCTAssertEqual(try Data(contentsOf: urls.quarantine), Data("foreign".utf8))
        XCTAssertEqual(try Data(contentsOf: urls.displaced), Data("owned".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testRetirementRemovesInterruptedPendingMarkerWithoutCanonicalMarker() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        try fixture.paths.ensureIsolationDirectories()
        let pending = fixture.paths.isolationURL.appendingPathComponent(
            ".ambiguity-owner-v1.pending"
        )
        try Data("interrupted".utf8).write(to: pending, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: pending.path
        )

        try SubjectIsolationCoordinator.cancelPendingAmbiguity(
            projectPaths: fixture.paths
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    func testRetirementCancellationDuringRecursiveCleanupIsBounded() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let outcome = try await SubjectIsolationCoordinator(
            nativeOperation: CoordinatorNativeHarness(
                plans: [.noSubject, .ambiguity, .ambiguity]
            ).run,
            maskAcquisition: CoordinatorMaskHarness().acquire
        ).isolate(
            request: fixture.request(),
            onProgress: { _ in },
            onLog: { _, _ in }
        )
        guard case .ambiguity(let choice) = outcome else {
            return XCTFail("Expected ambiguity.")
        }
        let ownedRun = choice.combinedInstanceLabelMaskURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for ordinal in 0..<64 {
            try Data("owned-\(ordinal)".utf8).write(
                to: ownedRun.appendingPathComponent(
                    String(format: "cleanup-%03d.txt", ordinal)
                ),
                options: .withoutOverwriting
            )
        }
        let checkpoints = CoordinatorCleanupCheckpointCapture()
        let retiredCapture = CoordinatorURLCapture()

        let task = Task {
            try SubjectIsolationCoordinator.cancelPendingAmbiguity(
                projectPaths: fixture.paths,
                beforeOwnedStagingRemoval: { retiredCapture.record($0) },
                cleanupCheckpoint: { checkpoint in
                    guard case .willQuarantine(_) = checkpoint else { return }
                    checkpoints.record(checkpoint)
                    if checkpoints.count == 4 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            )
        }

        do {
            try await task.value
            XCTFail("Expected cancellation from inside recursive cleanup.")
        } catch is CancellationError {
            XCTAssertEqual(checkpoints.count, 4)
            let retired = try retiredCapture.value()
            XCTAssertTrue(FileManager.default.fileExists(atPath: retired.path))
            XCTAssertFalse(
                try FileManager.default.contentsOfDirectory(atPath: retired.path).isEmpty
            )
        }
    }

    func testRetirementFailureRetainsAuthorityForUnremovedOwnedStaging() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let outcome = try await SubjectIsolationCoordinator(
            nativeOperation: CoordinatorNativeHarness(
                plans: [.noSubject, .ambiguity, .ambiguity]
            ).run,
            maskAcquisition: CoordinatorMaskHarness().acquire
        ).isolate(
            request: fixture.request(),
            onProgress: { _ in },
            onLog: { _, _ in }
        )
        guard case .ambiguity(let choice) = outcome else {
            return XCTFail("Expected ambiguity.")
        }
        let ownedRun = choice.combinedInstanceLabelMaskURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let blocker = ownedRun.appendingPathComponent("cleanup-blocker.fifo")
        XCTAssertEqual(Darwin.mkfifo(blocker.path, mode_t(0o600)), 0)
        let marker = fixture.paths.isolationURL.appendingPathComponent(
            ".ambiguity-owner-v1"
        )
        let markerBytes = try Data(contentsOf: marker)

        XCTAssertThrowsError(
            try SubjectIsolationCoordinator.cancelPendingAmbiguity(
                projectPaths: fixture.paths
            )
        )

        XCTAssertEqual(try Data(contentsOf: marker), markerBytes)
        let retired = try FileManager.default.contentsOfDirectory(
            at: fixture.paths.isolationStagingURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".retired-ambiguity-") }
        XCTAssertEqual(retired.count, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: retired[0].appendingPathComponent(
                    "cleanup-blocker.fifo"
                ).path
            )
        )
    }

    func testRetirementCancellationDuringNearMaximumReaddirIsBounded() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let outcome = try await SubjectIsolationCoordinator(
            nativeOperation: CoordinatorNativeHarness(
                plans: [.noSubject, .ambiguity, .ambiguity]
            ).run,
            maskAcquisition: CoordinatorMaskHarness().acquire
        ).isolate(
            request: fixture.request(),
            onProgress: { _ in },
            onLog: { _, _ in }
        )
        guard case .ambiguity(let choice) = outcome else {
            return XCTFail("Expected ambiguity.")
        }
        let ownedRun = choice.combinedInstanceLabelMaskURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try createEmptyFiles(
            count: 49_000,
            in: ownedRun,
            prefix: "near-limit"
        )
        let observedCount = CoordinatorIntegerCapture()

        let task = Task {
            try SubjectIsolationCoordinator.cancelPendingAmbiguity(
                projectPaths: fixture.paths,
                beforeOwnedStagingRemoval: { _ in },
                cleanupCheckpoint: { checkpoint in
                    guard case .didReadDirectoryEntry(let count) = checkpoint else {
                        return
                    }
                    observedCount.record(count)
                    if count == 49_000 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            )
        }

        do {
            try await task.value
            XCTFail("Expected cancellation during the near-limit readdir pass.")
        } catch is CancellationError {
            XCTAssertEqual(observedCount.value, 49_000)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: fixture.paths.isolationURL.appendingPathComponent(
                        ".ambiguity-owner-v1"
                    ).path
                )
            )
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: fixture.paths.isolationStagingURL.path
                ).filter { $0.hasPrefix(".retired-ambiguity-") }.count,
                1
            )
        }
    }

    func testAmbiguityClaimRejectsReplacedOwnedStagingDirectory() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let replacement = CoordinatorStagingReplacementCapture()
        let marker = fixture.paths.isolationURL.appendingPathComponent(
            ".ambiguity-owner-v1"
        )

        do {
            _ = try await SubjectIsolationCoordinator(
                nativeOperation: CoordinatorNativeHarness(
                    plans: [.noSubject, .ambiguity, .ambiguity]
                ).run,
                maskAcquisition: CoordinatorMaskHarness().acquire,
                ambiguityLeaseCheckpoint: { checkpoint, isolationURL in
                    guard checkpoint == .claimWillBindStaging else { return }
                    let stagingRoot = isolationURL.appendingPathComponent(
                        "staging",
                        isDirectory: true
                    )
                    let runs = try FileManager.default.contentsOfDirectory(
                        at: stagingRoot,
                        includingPropertiesForKeys: nil
                    ).filter { !$0.lastPathComponent.hasPrefix(".") }
                    guard runs.count == 1 else {
                        throw CoordinatorProbeError.expectedFailure
                    }
                    let active = runs[0]
                    let displaced = stagingRoot.appendingPathComponent(
                        ".displaced-owned-claim",
                        isDirectory: true
                    )
                    try FileManager.default.moveItem(at: active, to: displaced)
                    try FileManager.default.createDirectory(
                        at: active,
                        withIntermediateDirectories: false
                    )
                    let sentinel = active.appendingPathComponent("foreign.txt")
                    try Data("foreign".utf8).write(
                        to: sentinel,
                        options: .withoutOverwriting
                    )
                    replacement.record(
                        replacementURL: active,
                        displacedURL: displaced,
                        sentinelURL: sentinel
                    )
                }
            ).isolate(
                request: fixture.request(),
                onProgress: { _ in },
                onLog: { _, _ in }
            )
            XCTFail("A replacement run directory must not receive ambiguity authority.")
        } catch let error as SubjectIsolationCleanupFailure {
            XCTAssertTrue(
                error.primaryFailureSummary?.contains("invalidProject") == true
            )
            XCTAssertTrue(
                error.cleanupFailureSummary.contains("NSCocoaErrorDomain:512")
            )
        }

        let urls = try replacement.urls()
        XCTAssertEqual(try Data(contentsOf: urls.sentinel), Data("foreign".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls.replacement.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls.displaced.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testClaimKeepsCanonicalMarkerAbsentUntilCompleteAndDurable() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        try fixture.paths.ensureIsolationDirectories()
        let marker = fixture.paths.isolationURL.appendingPathComponent(
            ".ambiguity-owner-v1"
        )
        let pending = fixture.paths.isolationURL.appendingPathComponent(
            ".ambiguity-owner-v1.pending"
        )
        try Data("interrupted".utf8).write(to: pending, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: pending.path
        )
        let checkpoints = SubjectLeaseCheckpointCapture()

        let outcome = try await SubjectIsolationCoordinator(
            nativeOperation: CoordinatorNativeHarness(
                plans: [.noSubject, .ambiguity, .ambiguity]
            ).run,
            maskAcquisition: CoordinatorMaskHarness().acquire,
            ambiguityLeaseCheckpoint: { checkpoint, _ in
                checkpoints.record(checkpoint)
                if checkpoint == .markerTemporaryWritten
                    || checkpoint == .markerTemporarySynchronized {
                    XCTAssertFalse(
                        FileManager.default.fileExists(atPath: marker.path),
                        "Canonical authority must remain absent until the temp is durable."
                    )
                    XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
                }
            }
        ).isolate(
            request: fixture.request(),
            onProgress: { _ in },
            onLog: { _, _ in }
        )

        guard case .ambiguity = outcome else {
            return XCTFail("Expected ambiguity after recovering the interrupted temp marker.")
        }
        XCTAssertTrue(checkpoints.values.contains(.markerTemporaryWritten))
        XCTAssertTrue(checkpoints.values.contains(.markerTemporarySynchronized))
        XCTAssertTrue(checkpoints.values.contains(.markerCanonicalPublished))
        XCTAssertTrue(checkpoints.values.contains(.claimDurable))
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    func testClaimFailureAfterCanonicalMarkerPublicationRollsBackAuthority() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        let marker = fixture.paths.isolationURL.appendingPathComponent(
            ".ambiguity-owner-v1"
        )
        let pending = fixture.paths.isolationURL.appendingPathComponent(
            ".ambiguity-owner-v1.pending"
        )

        do {
            _ = try await SubjectIsolationCoordinator(
                nativeOperation: CoordinatorNativeHarness(
                    plans: [.noSubject, .ambiguity, .ambiguity]
                ).run,
                maskAcquisition: CoordinatorMaskHarness().acquire,
                ambiguityLeaseCheckpoint: { checkpoint, _ in
                    if checkpoint == .claimDurable {
                        throw CoordinatorProbeError.expectedFailure
                    }
                }
            ).isolate(
                request: fixture.request(),
                onProgress: { _ in },
                onLog: { _, _ in }
            )
            XCTFail("Expected the injected post-publication failure.")
        } catch let error as SubjectIsolationCoordinatorError {
            XCTAssertEqual(error, .invalidProject)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.paths.isolationStagingURL.path
            ),
            []
        )
    }

    func testCancellationAfterMarkerPublicationRollsBackAuthorityNoncancellably() async throws {
        for cancellationPoint in [
            SubjectIsolationAmbiguityLeaseCheckpoint.markerTemporaryWritten,
            .markerTemporarySynchronized,
            .markerCanonicalPublished,
            .claimDurable,
        ] {
            try await withCoordinatorFixture { fixture in
                let task = Task {
                    try await SubjectIsolationCoordinator(
                        nativeOperation: CoordinatorNativeHarness(
                            plans: [.noSubject, .ambiguity, .ambiguity]
                        ).run,
                        maskAcquisition: CoordinatorMaskHarness().acquire,
                        ambiguityLeaseCheckpoint: { checkpoint, _ in
                            guard checkpoint == cancellationPoint else { return }
                            withUnsafeCurrentTask { $0?.cancel() }
                            throw CancellationError()
                        }
                    ).isolate(
                        request: fixture.request(),
                        onProgress: { _ in },
                        onLog: { _, _ in }
                    )
                }

                do {
                    _ = try await task.value
                    XCTFail("Expected cancellation at \(cancellationPoint).")
                } catch is CancellationError {
                    XCTAssertFalse(
                        FileManager.default.fileExists(
                            atPath: fixture.paths.isolationURL.appendingPathComponent(
                                ".ambiguity-owner-v1"
                            ).path
                        )
                    )
                    XCTAssertFalse(
                        FileManager.default.fileExists(
                            atPath: fixture.paths.isolationURL.appendingPathComponent(
                                ".ambiguity-owner-v1.pending"
                            ).path
                        )
                    )
                    XCTAssertEqual(
                        try FileManager.default.contentsOfDirectory(
                            atPath: fixture.paths.isolationStagingURL.path
                        ),
                        []
                    )
                }
            }
        }
    }

    func testAlreadyCancelledCoordinatorStopsBeforeCanonicalValidationOrStaging() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.cleanup() }
        try FileManager.default.removeItem(at: fixture.paths.isolationURL)
        try FileManager.default.removeItem(at: fixture.paths.outputSplatReceiptURL)
        let native = CoordinatorNativeHarness(plans: [.complete])
        let masks = CoordinatorMaskHarness()

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SubjectIsolationCoordinator(
                nativeOperation: native.run,
                maskAcquisition: masks.acquire
            ).isolate(
                request: fixture.request(),
                onProgress: { _ in XCTFail("Cancelled work must report no progress.") },
                onLog: { _, _ in }
            )
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation before project validation.")
        } catch is CancellationError {
            XCTAssertTrue(native.records.isEmpty)
            XCTAssertTrue(masks.batchSizes.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: fixture.paths.isolationURL.path
            ))
        }
    }
}

private struct CoordinatorFixture {
    let base: SubjectIsolationFixture
    let executable: URL
    let metallib: URL
    let publication: CanonicalSplatPublication

    var paths: ProjectPaths { base.paths }

    init() throws {
        base = try makeCoordinatorSubjectIsolationFixture(maskCount: 24)
        executable = base.root.appendingPathComponent("easysplat-train")
        FileManager.default.createFile(atPath: executable.path, contents: Data("native".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        metallib = base.root.appendingPathComponent("default.metallib")
        try Data("metallib".utf8).write(to: metallib, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metallib.path)
        let sparse = base.paths.trainingURL.appendingPathComponent(
            "msplat_dataset/sparse/0",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: sparse, withIntermediateDirectories: true)
        let poses = (0..<24).map { index in
            "\(index + 1) 1 0 0 0 \(Double(index)) 0 0 1 frame-\(index).png\n\n"
        }.joined()
        try poses.write(
            to: sparse.appendingPathComponent("images.txt"),
            atomically: true,
            encoding: .utf8
        )
        publication = try SubjectIsolationArtifactStore.captureCanonicalPublication(
            paths: base.paths
        )
    }

    func cleanup() {
        base.cleanup()
    }

    func request(anchor: SubjectAnchor? = nil) -> SubjectIsolationRequest {
        SubjectIsolationRequest(
            projectPaths: paths,
            nativeExecutableURL: executable,
            nativeMetallibURL: metallib,
            toolchainBuildIdentity: "test-toolchain-build",
            memoryBudgetBytes: 1_073_741_824,
            anchor: anchor
        )
    }
}

private func withCoordinatorFixture(
    _ operation: (CoordinatorFixture) async throws -> Void
) async throws {
    let fixture = try CoordinatorFixture()
    defer { fixture.cleanup() }
    try await operation(fixture)
}

private func makeCoordinatorSubjectIsolationFixture(
    maskCount: Int
) throws -> SubjectIsolationFixture {
    let root = try TestFileBuilder.makeTempDir()
    let paths = ProjectPaths(root: root)
    let projectID = UUID(
        uuidString: "99999999-8888-4777-8666-555555555555"
    )!
    try paths.ensureDirectories()
    let (_, photoReceipt) = try TestFileBuilder.writeControlledPhotoReceipt(
        paths: paths
    )
    let requestedOptions = RequestedRunOptions(
        capturePath: .orbit,
        detailProfile: .balanced,
        cameraGrouping: .sameCameraAndLens,
        lensProjection: .perspective,
        inputOrdering: .automatic,
        resourcePolicy: .maximumPerformance,
        photoSelection: .useAllValidPhotos
    )
    let input = InputSpec.photos(folder: "Originals/Photos")
    let plan = RunPlanResolver.resolve(
        requestedOptions: requestedOptions,
        input: input,
        hardware: HardwareProfile(
            memoryGB: 48,
            cpuCount: 16,
            gpuWorkingSetGB: 36
        ),
        developmentOverrides: .none
    )
    let selectionArtifact = PhotoSelectionArtifact(
        strategy: .useAll,
        analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
        analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256,
        selectorPolicyVersion: PhotoDiversitySelector.selectorPolicyVersion,
        selectorPolicySHA256: PhotoDiversitySelector.selectorPolicySHA256,
        inputOrdering: plan.inputOrdering,
        requestedPhotoSelection: requestedOptions.photoSelection,
        admissionCapacity: 1,
        discoveredCount: 1,
        acceptedCount: 1,
        unreadableCount: 0,
        exactDuplicateCount: 0,
        companionDuplicateCount: 0,
        candidates: [
            PhotoSelectionCandidateArtifact(
                admissionOrdinal: 0,
                evidence: photoReceipt.analysisEvidence,
                retainedRank: 0
            ),
        ],
        retainedSourceSHA256s: [photoReceipt.source.sha256],
        canonicalRetainedSourceSHA256s: [photoReceipt.source.sha256]
    )
    let selectionFile = try PhotoSelectionArtifactStore.save(
        selectionArtifact,
        to: paths.photoSelectionArtifactURL,
        projectPaths: paths
    )
    let selectionReceipt = PhotoSelectionReceipt(
        projectRelativePath: PhotoSelectionReceipt.projectRelativePath,
        byteCount: selectionFile.byteCount,
        sha256: selectionFile.sha256,
        artifactSchemaVersion: selectionArtifact.schemaVersion,
        analysisRecipeVersion: selectionArtifact.analysisRecipeVersion,
        analysisRecipeSHA256: selectionArtifact.analysisRecipeSHA256,
        selectorPolicyVersion: selectionArtifact.selectorPolicyVersion,
        selectorPolicySHA256: selectionArtifact.selectorPolicySHA256
    )
    try ProjectMetadataStore.save(
        ProjectMetadata(
            id: projectID,
            title: "Subject isolation coordinator fixture",
            input: input,
            photoInputReceipts: [photoReceipt],
            photoSelectionReceipt: selectionReceipt,
            requestedRunOptions: requestedOptions,
            resolvedRunPlan: plan
        ),
        to: paths.metadataURL
    )
    try TestFileBuilder.writeMinimalPly(at: paths.outputSplatURL)
    guard Darwin.chmod(paths.outputSplatURL.path, 0o600) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    let outputEvidence = try ProjectArtifactValidator.validatedPlyEvidence(
        at: paths.outputSplatURL
    )
    var training = makeTrainingArtifact()
    training.outputSHA256 = outputEvidence.sha256
    training.outputBytes = Int64(outputEvidence.byteCount)
    training.gaussianCount = outputEvidence.vertexCount
    training.sceneBounds = outputEvidence.sceneBounds
    training.datasetDerivation.registeredImageNames = (0..<maskCount).map {
        "frame-\($0).png"
    }
    let datasetImages = paths.trainingURL.appendingPathComponent(
        "msplat_dataset/images",
        isDirectory: true
    )
    for index in 0..<maskCount {
        XCTAssertTrue(
            try TestFileBuilder.writeGrayscaleImage(
                url: datasetImages.appendingPathComponent("frame-\(index).png"),
                size: 4,
                value: UInt8(index % 255),
                utType: .png
            )
        )
    }
    try TrainingArtifactStore.persist(training, paths: paths)

    let publicationID = UUID(
        uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
    )!
    let publishedAt = Date(timeIntervalSince1970: 1_767_225_600)
    let trainingDuration = training.elapsedSeconds ?? 0
    let runID = UUID(
        uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
    )!
    let staging = paths.isolationStagingURL(for: runID)
    let fixture = SubjectIsolationFixture(
        root: root,
        paths: paths,
        projectID: projectID,
        publicationID: publicationID,
        runID: runID,
        training: training,
        stagedOutputURL: staging.appendingPathComponent("isolated.ply"),
        stagedMasksURL: staging.appendingPathComponent("masks", isDirectory: true),
        maskCount: maskCount
    )
    let trainingManifest = try Data(contentsOf: paths.trainingManifestURL)
    let geometry = makeGeometryArtifact()
    let receipt = PublishedSplatReceipt(
        publicationID: publicationID,
        projectID: projectID,
        publishedAt: publishedAt,
        outputEvidence: outputEvidence,
        lineage: PublishedSplatLineage(
            trainingManifestSHA256: SHA256.hash(data: trainingManifest)
                .map { String(format: "%02x", $0) }
                .joined(),
            trainingInputDigest: training.inputDigest,
            trainingGeometryDigest: training.geometryDigest
        ),
        presentation: PublishedResultPresentation(
            requestedRunOptions: requestedOptions,
            resolvedRunPlan: plan,
            reconstruction: PublishedReconstructionSummary(
                registeredViewCount: geometry.registeredViewCount,
                totalViewCount: geometry.totalViewCount,
                pointCount: geometry.pointCount,
                observationCount: geometry.observationCount,
                medianPixelResidual: geometry.medianPixelResidual,
                p90PixelResidual: geometry.p90PixelResidual,
                solverVersion: geometry.solverVersion,
                modelVersion: geometry.modelVersion,
                cameraModel: geometry.cameraModel,
                residualProvenance: "colmap-text-tracks-v1",
                usedPartialCoverageAcceptance: false,
                secondLargestModelRegisteredViewCount: 0
            ),
            orientation: PublishedOrientationSummary(geometry: geometry),
            stageTimings: [
                StageTimingRecord(
                    stage: .trainSplat,
                    startedAt: publishedAt.addingTimeInterval(-trainingDuration),
                    durationSeconds: trainingDuration
                ),
            ],
            autoTunerSnapshot: PublishedAutoTunerSnapshot(
                resolvedRunPlan: plan
            ),
            trainerVersion: training.trainerVersion,
            runtimeVersion: training.runtimeVersion,
            completedIteration: min(
                training.completedIteration,
                plan.trainerIterationLimit
            ),
            trainingDurationSeconds: trainingDuration,
            createToViewerReadySeconds: nil
        )
    )
    try PublishedSplatReceiptStore.encode(receipt).write(
        to: paths.outputSplatReceiptURL,
        options: .atomic
    )
    guard Darwin.chmod(paths.outputSplatReceiptURL.path, 0o600) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return fixture
}

private enum CoordinatorProbeError: Error {
    case expectedFailure
    case timeout
}

private enum CoordinatorCancellationResult: Equatable {
    case completed
    case cancelled
    case failed(String)
}

private final class CoordinatorCancellationResultCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: CoordinatorCancellationResult?

    var value: CoordinatorCancellationResult? {
        lock.withLock { storage }
    }

    func record(_ value: CoordinatorCancellationResult) {
        lock.withLock { storage = value }
    }
}

private final class CoordinatorStagingReplacementCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var replacementURL: URL?
    private var displacedURL: URL?
    private var sentinelURL: URL?

    func record(replacementURL: URL, displacedURL: URL, sentinelURL: URL) {
        lock.withLock {
            self.replacementURL = replacementURL
            self.displacedURL = displacedURL
            self.sentinelURL = sentinelURL
        }
    }

    func urls() throws -> (replacement: URL, displaced: URL, sentinel: URL) {
        try lock.withLock {
            guard let replacementURL, let displacedURL, let sentinelURL else {
                throw CoordinatorProbeError.expectedFailure
            }
            return (replacementURL, displacedURL, sentinelURL)
        }
    }
}

private final class CoordinatorLockRaceCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var contention = false
    private var completion = false

    var didContend: Bool { lock.withLock { contention } }
    var didComplete: Bool { lock.withLock { completion } }

    func recordContention() {
        lock.withLock { contention = true }
    }

    func recordCompletion() {
        lock.withLock { completion = true }
    }
}

private final class CoordinatorURLCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?

    func record(_ value: URL) {
        lock.withLock { stored = value }
    }

    func value() throws -> URL {
        try lock.withLock {
            guard let stored else { throw CoordinatorProbeError.expectedFailure }
            return stored
        }
    }
}

private final class CoordinatorQuarantineRaceCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var quarantineURL: URL?
    private var displacedURL: URL?

    func record(quarantineURL: URL, displacedURL: URL) {
        lock.withLock {
            self.quarantineURL = quarantineURL
            self.displacedURL = displacedURL
        }
    }

    func urls() throws -> (quarantine: URL, displaced: URL) {
        try lock.withLock {
            guard let quarantineURL, let displacedURL else {
                throw CoordinatorProbeError.expectedFailure
            }
            return (quarantineURL, displacedURL)
        }
    }
}

private final class CoordinatorIntegerCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int { lock.withLock { stored } }

    func record(_ value: Int) {
        lock.withLock { stored = max(stored, value) }
    }
}

private final class CoordinatorOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

private final class CoordinatorCleanupCheckpointCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SubjectIsolationAmbiguityCleanupCheckpoint] = []

    var count: Int { lock.withLock { storage.count } }

    func record(_ checkpoint: SubjectIsolationAmbiguityCleanupCheckpoint) {
        lock.withLock { storage.append(checkpoint) }
    }
}

private final class SubjectLeaseCheckpointCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SubjectIsolationAmbiguityLeaseCheckpoint] = []

    var values: [SubjectIsolationAmbiguityLeaseCheckpoint] {
        lock.withLock { storage }
    }

    func record(_ value: SubjectIsolationAmbiguityLeaseCheckpoint) {
        lock.withLock { storage.append(value) }
    }
}

private final class TransientNativeRuntimeSwapHarness: @unchecked Sendable {
    let replacementExecutableBytes = Data("replacement-native".utf8)
    let replacementMetallibBytes = Data("replacement-metallib".utf8)

    private let executableURL: URL
    private let metallibURL: URL
    private let native = CoordinatorNativeHarness(plans: [.complete])
    private let lock = NSLock()
    private var executableObservation: Data?
    private var metallibObservation: Data?

    var observedExecutableBytes: Data? { lock.withLock { executableObservation } }
    var observedMetallibBytes: Data? { lock.withLock { metallibObservation } }

    init(executableURL: URL, metallibURL: URL) {
        self.executableURL = executableURL
        self.metallibURL = metallibURL
    }

    func run(
        request: SubjectIsolationNativeRunRequest,
        onProgress: @escaping @Sendable (SubjectIsolationProgress) -> Void,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> SubjectIsolationNativeRunResult {
        let executableBackup = executableURL.deletingLastPathComponent()
            .appendingPathComponent(".original-executable-\(UUID().uuidString)")
        let metallibBackup = metallibURL.deletingLastPathComponent()
            .appendingPathComponent(".original-metallib-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: executableURL, to: executableBackup)
        try FileManager.default.moveItem(at: metallibURL, to: metallibBackup)
        do {
            try replacementExecutableBytes.write(to: executableURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: executableURL.path
            )
            try replacementMetallibBytes.write(to: metallibURL, options: .withoutOverwriting)
            let observedExecutable = try Data(contentsOf: request.executableURL)
            let observedMetallib = try Data(contentsOf: request.metallibURL)
            lock.withLock {
                executableObservation = observedExecutable
                metallibObservation = observedMetallib
            }
            try FileManager.default.removeItem(at: executableURL)
            try FileManager.default.removeItem(at: metallibURL)
            try FileManager.default.moveItem(at: executableBackup, to: executableURL)
            try FileManager.default.moveItem(at: metallibBackup, to: metallibURL)
        } catch {
            try? FileManager.default.removeItem(at: executableURL)
            try? FileManager.default.removeItem(at: metallibURL)
            try? FileManager.default.moveItem(at: executableBackup, to: executableURL)
            try? FileManager.default.moveItem(at: metallibBackup, to: metallibURL)
            throw error
        }
        return try await native.run(
            request: request,
            onProgress: onProgress,
            onLog: onLog
        )
    }
}

private final class TransientPrivateNativeRuntimeSwapHarness: @unchecked Sendable {
    let replacementExecutableBytes = Data("replacement-private-native".utf8)
    let replacementMetallibBytes = Data("replacement-private-metallib".utf8)

    private let native = CoordinatorNativeHarness(plans: [.complete])
    private let lock = NSLock()
    private var executableObservation: Data?
    private var metallibObservation: Data?

    var observedExecutableBytes: Data? { lock.withLock { executableObservation } }
    var observedMetallibBytes: Data? { lock.withLock { metallibObservation } }

    func run(
        request: SubjectIsolationNativeRunRequest,
        onProgress: @escaping @Sendable (SubjectIsolationProgress) -> Void,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> SubjectIsolationNativeRunResult {
        let runtime = request.outputURL.deletingLastPathComponent()
            .appendingPathComponent(".native-runtime", isDirectory: true)
        let namedExecutable = runtime.appendingPathComponent("easysplat-train")
        let namedMetallib = runtime.appendingPathComponent("default.metallib")
        let executableBackup = runtime.appendingPathComponent(
            ".original-executable-\(UUID().uuidString)"
        )
        let metallibBackup = runtime.appendingPathComponent(
            ".original-metallib-\(UUID().uuidString)"
        )
        guard Darwin.chflags(runtime.path, 0) == 0,
              Darwin.chflags(namedExecutable.path, 0) == 0,
              Darwin.chflags(namedMetallib.path, 0) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        try FileManager.default.moveItem(
            at: namedExecutable,
            to: executableBackup
        )
        try FileManager.default.moveItem(
            at: namedMetallib,
            to: metallibBackup
        )
        var restored = false
        defer {
            if !restored {
                try? restore(
                    runtime: runtime,
                    namedExecutable: namedExecutable,
                    namedMetallib: namedMetallib,
                    executableBackup: executableBackup,
                    metallibBackup: metallibBackup
                )
            }
        }

        try replacementExecutableBytes.write(
            to: namedExecutable,
            options: .withoutOverwriting
        )
        try replacementMetallibBytes.write(
            to: namedMetallib,
            options: .withoutOverwriting
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: namedExecutable.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: namedMetallib.path
        )
        lock.withLock {
            executableObservation = try? Data(contentsOf: request.executableURL)
            metallibObservation = try? Data(contentsOf: request.metallibURL)
        }
        let result = try await native.run(
            request: request,
            onProgress: onProgress,
            onLog: onLog
        )
        try restore(
            runtime: runtime,
            namedExecutable: namedExecutable,
            namedMetallib: namedMetallib,
            executableBackup: executableBackup,
            metallibBackup: metallibBackup
        )
        restored = true
        return result
    }

    private func restore(
        runtime: URL,
        namedExecutable: URL,
        namedMetallib: URL,
        executableBackup: URL,
        metallibBackup: URL
    ) throws {
        if FileManager.default.fileExists(atPath: namedExecutable.path) {
            try FileManager.default.removeItem(at: namedExecutable)
        }
        if FileManager.default.fileExists(atPath: namedMetallib.path) {
            try FileManager.default.removeItem(at: namedMetallib)
        }
        if FileManager.default.fileExists(atPath: executableBackup.path) {
            try FileManager.default.moveItem(
                at: executableBackup,
                to: namedExecutable
            )
        }
        if FileManager.default.fileExists(atPath: metallibBackup.path) {
            try FileManager.default.moveItem(
                at: metallibBackup,
                to: namedMetallib
            )
        }
        guard Darwin.chflags(
            namedExecutable.path,
            UInt32(UF_IMMUTABLE)
        ) == 0,
        Darwin.chflags(
            namedMetallib.path,
            UInt32(UF_IMMUTABLE)
        ) == 0,
        Darwin.chflags(runtime.path, UInt32(UF_IMMUTABLE)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}

private final class TransientPrivateNativeAncestorSwapHarness: @unchecked Sendable {
    let replacementExecutableBytes = Data("ancestor-replacement-native".utf8)
    let replacementMetallibBytes = Data("ancestor-replacement-metallib".utf8)

    private let native = CoordinatorNativeHarness(plans: [.complete])
    private let lock = NSLock()
    private var executableObservation: Data?
    private var metallibObservation: Data?

    var observedExecutableBytes: Data? { lock.withLock { executableObservation } }
    var observedMetallibBytes: Data? { lock.withLock { metallibObservation } }

    func run(
        request: SubjectIsolationNativeRunRequest,
        onProgress: @escaping @Sendable (SubjectIsolationProgress) -> Void,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> SubjectIsolationNativeRunResult {
        let runDirectory = request.outputURL.deletingLastPathComponent()
        let displaced = runDirectory.deletingLastPathComponent()
            .appendingPathComponent(
                ".displaced-native-run-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.moveItem(at: runDirectory, to: displaced)
        var restored = false
        defer {
            if !restored {
                try? FileManager.default.removeItem(at: runDirectory)
                try? FileManager.default.moveItem(at: displaced, to: runDirectory)
            }
        }

        let replacementRuntime = runDirectory.appendingPathComponent(
            ".native-runtime",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: replacementRuntime,
            withIntermediateDirectories: true
        )
        let replacementExecutable = replacementRuntime.appendingPathComponent(
            "easysplat-train"
        )
        let replacementMetallib = replacementRuntime.appendingPathComponent(
            "default.metallib"
        )
        try replacementExecutableBytes.write(
            to: replacementExecutable,
            options: .withoutOverwriting
        )
        try replacementMetallibBytes.write(
            to: replacementMetallib,
            options: .withoutOverwriting
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: replacementExecutable.path
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o400],
            ofItemAtPath: replacementMetallib.path
        )

        let observedExecutable = try Data(contentsOf: request.executableURL)
        let observedMetallib = try Data(contentsOf: request.metallibURL)
        lock.withLock {
            executableObservation = observedExecutable
            metallibObservation = observedMetallib
        }

        try FileManager.default.removeItem(at: runDirectory)
        try FileManager.default.moveItem(at: displaced, to: runDirectory)
        restored = true
        return try await native.run(
            request: request,
            onProgress: onProgress,
            onLog: onLog
        )
    }
}

private final class RealSubprocessPrivateRuntimeHarness: @unchecked Sendable {
    private let native = CoordinatorNativeHarness(plans: [.complete])
    private let lock = NSLock()
    private var storedExecutablePath = ""
    private var storedMetallibPath = ""
    private var storedStandardOutput = Data()

    var executablePath: String { lock.withLock { storedExecutablePath } }
    var metallibPath: String { lock.withLock { storedMetallibPath } }
    var standardOutput: Data { lock.withLock { storedStandardOutput } }

    func run(
        request: SubjectIsolationNativeRunRequest,
        onProgress: @escaping @Sendable (SubjectIsolationProgress) -> Void,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> SubjectIsolationNativeRunResult {
        let runDirectory = request.outputURL.deletingLastPathComponent()
        let displaced = runDirectory.deletingLastPathComponent()
            .appendingPathComponent(
                ".displaced-real-native-run-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.moveItem(at: runDirectory, to: displaced)
        var restored = false
        defer {
            if !restored {
                try? FileManager.default.removeItem(at: runDirectory)
                try? FileManager.default.moveItem(at: displaced, to: runDirectory)
            }
        }

        let replacementRuntime = runDirectory.appendingPathComponent(
            ".native-runtime",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: replacementRuntime,
            withIntermediateDirectories: true
        )
        let replacementExecutable = replacementRuntime.appendingPathComponent(
            "easysplat-train"
        )
        try Data(
            "#!/bin/sh\nprintf MALICIOUS:\n/bin/cat \"$1\"\n".utf8
        ).write(to: replacementExecutable, options: .withoutOverwriting)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: replacementExecutable.path
        )
        try Data("malicious-metallib".utf8).write(
            to: replacementRuntime.appendingPathComponent("default.metallib"),
            options: .withoutOverwriting
        )

        let process = Process()
        process.executableURL = request.executableURL
        process.arguments = [request.metallibURL.path]
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let error = standardError.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            throw NSError(
                domain: "RealSubprocessPrivateRuntimeHarness",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: String(
                    data: error,
                    encoding: .utf8
                ) ?? "subprocess failed"]
            )
        }
        lock.withLock {
            storedExecutablePath = request.executableURL.path
            storedMetallibPath = request.metallibURL.path
            storedStandardOutput = output
        }

        try FileManager.default.removeItem(at: runDirectory)
        try FileManager.default.moveItem(at: displaced, to: runDirectory)
        restored = true
        return try await native.run(
            request: request,
            onProgress: onProgress,
            onLog: onLog
        )
    }
}

private final class CoordinatorMaskHarness: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedBatchSizes: [Int] = []
    private var recordedIdentities: [String] = []

    var batchSizes: [Int] { lock.withLock { recordedBatchSizes } }
    var imageIdentities: [String] { lock.withLock { recordedIdentities } }

    func acquire(
        views: [SubjectIsolationAnalysisView],
        stagingDirectory: URL,
        startingOrdinal: Int,
        shouldCancel: @escaping @Sendable () -> Bool
    ) async throws -> [SubjectIsolationAcquiredMask] {
        if shouldCancel() { throw CancellationError() }
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        lock.withLock {
            recordedBatchSizes.append(views.count)
            recordedIdentities.append(contentsOf: views.map(\.imageIdentity))
        }
        return try views.enumerated().map { offset, view in
            let file = stagingDirectory.appendingPathComponent(
                String(format: "%04d.png", startingOrdinal + offset)
            )
            XCTAssertTrue(
                try TestFileBuilder.writeGrayscaleImage(
                    url: file,
                    size: 4,
                    value: 1,
                    utType: .png
                )
            )
            return SubjectIsolationAcquiredMask(
                fileURL: file,
                imageIdentity: view.imageIdentity,
                imageSHA256: try GeometryArtifactStore.sha256(of: view.imageURL),
                maskSHA256: try GeometryArtifactStore.sha256(of: file),
                pixelWidth: 4,
                pixelHeight: 4,
                instanceLabels: [1]
            )
        }
    }
}

private final class CoordinatorNativeHarness: @unchecked Sendable {
    enum Plan: Equatable {
        case noSubject
        case ambiguity
        case splitKeyframeAmbiguity
        case heldOutRejected
        case complete
        case cancel
    }

    struct Record {
        let viewCount: Int
        let analysisCacheURL: URL
        let outputURL: URL
        let maskManifestURL: URL
        let anchor: SubjectAnchor?
    }

    private let lock = NSLock()
    private var plans: [Plan]
    private var storage: [Record] = []

    var records: [Record] { lock.withLock { storage } }

    init(plans: [Plan]) {
        self.plans = plans
    }

    func run(
        request: SubjectIsolationNativeRunRequest,
        onProgress: @escaping @Sendable (SubjectIsolationProgress) -> Void,
        onLog: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> SubjectIsolationNativeRunResult {
        let manifestData = try Data(contentsOf: request.maskManifestURL)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        let order = try XCTUnwrap(root["selected_image_order"] as? [String])
        let views = try XCTUnwrap(root["views"] as? [[String: Any]])
        XCTAssertEqual(order, views.compactMap { $0["image_identity"] as? String })
        XCTAssertEqual(root["schema_version"] as? Int, 1)
        XCTAssertEqual(root["isolation_mode_version"] as? Int, 1)
        XCTAssertEqual(root["source_ply_digest"] as? String, request.digests.sourcePly)
        XCTAssertEqual(root["input_digest"] as? String, request.digests.input)
        XCTAssertEqual(root["geometry_digest"] as? String, request.digests.geometry)
        XCTAssertEqual(root["selected_frames_digest"] as? String, request.digests.selectedFrames)
        XCTAssertEqual(root["training_manifest_digest"] as? String, request.digests.trainingManifest)
        let plan: Plan = lock.withLock {
            storage.append(Record(
                viewCount: views.count,
                analysisCacheURL: request.analysisCacheURL,
                outputURL: request.outputURL,
                maskManifestURL: request.maskManifestURL,
                anchor: request.anchor
            ))
            return plans.removeFirst()
        }
        let work = views.filter { ($0["role"] as? String) == "work" }
            .compactMap { $0["image_identity"] as? String }
        let heldOut = views.filter { ($0["role"] as? String) == "held_out" }
            .compactMap { $0["image_identity"] as? String }
        let keyframe = try XCTUnwrap(work.first)
        let component = SubjectIsolationNativeComponent(
            identity: "component-main",
            score: 0.9,
            keyframes: [
                SubjectIsolationNativeKeyframeContribution(
                    imageIdentity: keyframe,
                    instanceLabel: 1,
                    weight: 10,
                    fraction: 0.9
                ),
            ]
        )
        switch plan {
        case .noSubject:
            return .noSubject([component])
        case .ambiguity:
            return .ambiguity([component])
        case .splitKeyframeAmbiguity:
            let otherKeyframe = try XCTUnwrap(work.last)
            let otherComponent = SubjectIsolationNativeComponent(
                identity: "component-other",
                score: 0.8,
                keyframes: [
                    SubjectIsolationNativeKeyframeContribution(
                        imageIdentity: otherKeyframe,
                        instanceLabel: 7,
                        weight: 9,
                        fraction: 0.8
                    ),
                ]
            )
            return .ambiguity([component, otherComponent])
        case .heldOutRejected:
            return .heldOutRejected
        case .cancel:
            throw CancellationError()
        case .complete:
            try TestFileBuilder.writeMinimalPly(at: request.outputURL)
            let evidence = try ProjectArtifactValidator.validatedPlyEvidence(
                at: request.outputURL
            )
            return .completed(SubjectIsolationNativeCompletion(
                outputSHA256: evidence.sha256,
                outputByteCount: evidence.byteCount,
                gaussianCount: evidence.vertexCount,
                sceneBounds: evidence.sceneBounds,
                retainedGaussianFraction: 0.5,
                heldOutMeanIoU: 0.8,
                heldOutMedianIoU: 0.8,
                heldOutFirstQuartileIoU: 0.8,
                selectedViewIdentities: work,
                heldOutViewIdentities: heldOut,
                selectedComponent: component
            ))
        }
    }
}

private func createEmptyFiles(
    count: Int,
    in directory: URL,
    prefix: String
) throws {
    let parent = Darwin.open(
        directory.path,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard parent >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { Darwin.close(parent) }
    for ordinal in 0..<count {
        let leaf = String(format: "%@-%05d", prefix, ordinal)
        let descriptor = leaf.withCString {
            Darwin.openat(
                parent,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        Darwin.close(descriptor)
    }
    guard Darwin.fsync(parent) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

private func holdLegacyOFDLock(
    lockPath: String,
    readyPath: String,
    releasePath: String
) throws {
    let descriptor = Darwin.open(
        lockPath,
        O_RDWR | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { Darwin.close(descriptor) }

    var lock = Darwin.flock()
    lock.l_start = 0
    lock.l_len = 0
    lock.l_pid = 0
    lock.l_type = Int16(F_WRLCK)
    lock.l_whence = Int16(SEEK_SET)
    let lockResult = withUnsafeMutablePointer(to: &lock) {
        Darwin.fcntl(descriptor, F_OFD_SETLK, $0)
    }
    guard lockResult == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer {
        lock.l_type = Int16(F_UNLCK)
        _ = withUnsafeMutablePointer(to: &lock) {
            Darwin.fcntl(descriptor, F_OFD_SETLK, $0)
        }
    }

    let ready = Darwin.open(readyPath, O_WRONLY | O_CLOEXEC)
    guard ready >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    var signal: UInt8 = 1
    guard Darwin.write(ready, &signal, 1) == 1 else {
        let error = NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        Darwin.close(ready)
        throw error
    }
    Darwin.close(ready)

    let release = Darwin.open(releasePath, O_RDONLY | O_CLOEXEC)
    guard release >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { Darwin.close(release) }
    var released: UInt8 = 0
    while Darwin.read(release, &released, 1) < 0, errno == EINTR {}
    guard released == 1 else {
        throw CoordinatorProbeError.expectedFailure
    }
}

private func runCrossProcessRetirementHelper(
    projectRoot: URL,
    attemptedURL: URL,
    readyURL: URL,
    completedURL: URL
) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
        "xctest",
        "-XCTest",
        "EasySplatCoreTests.SubjectIsolationCoordinatorTests/testCrossProcessRetirementHelperEntryPoint",
        Bundle(for: SubjectIsolationCoordinatorTests.self).bundleURL.path,
    ]
    process.environment = ProcessInfo.processInfo.environment.merging([
        "EASYSPLAT_SUBJECT_LEASE_HELPER_MODE": "retire",
        "EASYSPLAT_SUBJECT_LEASE_HELPER_PROJECT": projectRoot.path,
        "EASYSPLAT_SUBJECT_LEASE_HELPER_ATTEMPTED": attemptedURL.path,
        "EASYSPLAT_SUBJECT_LEASE_HELPER_READY": readyURL.path,
        "EASYSPLAT_SUBJECT_LEASE_HELPER_COMPLETED": completedURL.path,
    ]) { _, new in new }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

private func runLegacyOFDLockHelper(
    lockURL: URL,
    readyURL: URL,
    releaseURL: URL
) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = [
        "xctest",
        "-XCTest",
        "EasySplatCoreTests.SubjectIsolationCoordinatorTests/testCrossProcessRetirementHelperEntryPoint",
        Bundle(for: SubjectIsolationCoordinatorTests.self).bundleURL.path,
    ]
    process.environment = ProcessInfo.processInfo.environment.merging([
        "EASYSPLAT_SUBJECT_LEASE_HELPER_MODE": "hold-legacy-ofd",
        "EASYSPLAT_SUBJECT_LEASE_HELPER_LOCK": lockURL.path,
        "EASYSPLAT_SUBJECT_LEASE_HELPER_READY": readyURL.path,
        "EASYSPLAT_SUBJECT_LEASE_HELPER_RELEASE": releaseURL.path,
    ]) { _, new in new }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
}

private func waitForSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: TimeInterval
) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(
                returning: semaphore.wait(timeout: .now() + timeout) == .success
            )
        }
    }
}

private func waitForProcess(
    _ process: Process,
    timeout: TimeInterval
) async -> Bool {
    await withCheckedContinuation { continuation in
        let gate = CoordinatorProcessWaitGate(continuation: continuation)
        process.terminationHandler = { _ in gate.finish(true) }
        if !process.isRunning { gate.finish(true) }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + timeout
        ) {
            gate.finish(false)
        }
    }
}

private func waitForFIFOByte(
    _ descriptor: Int32,
    timeout: TimeInterval
) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            let timeoutMilliseconds = Int32(
                max(0, min(timeout * 1_000, Double(Int32.max)))
            )
            let result = Darwin.poll(&pollDescriptor, 1, timeoutMilliseconds)
            guard result == 1,
                  pollDescriptor.revents & Int16(POLLIN) != 0 else {
                continuation.resume(returning: false)
                return
            }
            var byte: UInt8 = 0
            continuation.resume(
                returning: Darwin.read(descriptor, &byte, 1) == 1 && byte == 1
            )
        }
    }
}

private final class CoordinatorProcessWaitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Bool) {
        let pendingContinuation = lock.withLock {
            let pending = self.continuation
            self.continuation = nil
            return pending
        }
        pendingContinuation?.resume(returning: value)
    }
}
