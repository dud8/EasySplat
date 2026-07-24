import CryptoKit
import XCTest
@testable import EasySplatCore

final class SubjectIsolationCoordinatorTests: XCTestCase {
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
        XCTAssertEqual(output.url, fixture.paths.isolatedOutputURL)
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
}

private struct CoordinatorFixture {
    let base: SubjectIsolationFixture
    let executable: URL
    let publication: CanonicalSplatPublication

    var paths: ProjectPaths { base.paths }

    init() throws {
        base = try makeSubjectIsolationFixture(maskCount: 24)
        executable = base.root.appendingPathComponent("easysplat-train")
        FileManager.default.createFile(atPath: executable.path, contents: Data("native".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
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
            toolchainBuildIdentity: "test-toolchain-build",
            memoryBudgetBytes: 1_073_741_824,
            anchor: anchor
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
