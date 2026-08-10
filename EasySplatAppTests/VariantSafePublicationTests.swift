import AppKit
import Foundation
import XCTest
@testable import EasySplatApp
@testable import EasySplatCore

@MainActor
final class VariantSafePublicationTests: XCTestCase {
    func testPublicationSourceCapturesOriginalAndSubjectIdentityAndFilename() async throws {
        let fixture = try makePublicationFixture(title: "  Garden / Statue: Study  ")
        defer { fixture.cleanup() }
        let state = PublicationArtifactState(.valid(fixture.subjectArtifact, fixture.subjectOutput))
        let model = makeModel(fixture: fixture, artifactState: state)

        let original = try await model.validatedCurrentSplatForPublication()

        XCTAssertEqual(original.projectURL, fixture.projectURL.standardizedFileURL)
        XCTAssertEqual(original.variant, .original)
        XCTAssertEqual(original.outputURL, fixture.paths.outputSplatURL.standardizedFileURL)
        XCTAssertEqual(original.expectedIdentity, fixture.originalIdentity)
        XCTAssertEqual(original.defaultFilename, "Garden Statue Study.ply")

        model.subjectOutput = fixture.subjectOutput
        XCTAssertTrue(model.setSelectedSplatOutputVariant(.subject))

        let subject = try await model.validatedCurrentSplatForPublication()

        XCTAssertEqual(subject.projectURL, fixture.projectURL.standardizedFileURL)
        XCTAssertEqual(subject.variant, .subject)
        XCTAssertEqual(subject.outputURL, fixture.paths.isolatedOutputURL.standardizedFileURL)
        XCTAssertEqual(subject.expectedIdentity, fixture.subjectIdentity)
        XCTAssertEqual(subject.defaultFilename, "Garden Statue Study (Subject).ply")
    }

    func testMissingStaleOrInvalidSubjectRefusesPublication() async throws {
        let fixture = try makePublicationFixture()
        defer { fixture.cleanup() }

        for result in [
            IsolationArtifactLoadResult.noArtifact,
            .stale(.sourceOutput),
            .invalid,
        ] {
            let state = PublicationArtifactState(result)
            let model = makeModel(fixture: fixture, artifactState: state)
            model.subjectOutput = fixture.subjectOutput
            XCTAssertTrue(model.setSelectedSplatOutputVariant(.subject))

            do {
                _ = try await model.validatedCurrentSplatForPublication()
                XCTFail("Expected \(result) to refuse Subject publication.")
            } catch {
                XCTAssertTrue(error is CurrentSplatExportError)
            }
        }
    }

    func testCapturedSubjectSourceExportsSubjectAfterSelectionChanges() async throws {
        let fixture = try makePublicationFixture()
        defer { fixture.cleanup() }
        let state = PublicationArtifactState(.valid(fixture.subjectArtifact, fixture.subjectOutput))
        let model = makeModel(fixture: fixture, artifactState: state)
        model.subjectOutput = fixture.subjectOutput
        XCTAssertTrue(model.setSelectedSplatOutputVariant(.subject))
        let source = try await model.validatedCurrentSplatForPublication()

        XCTAssertTrue(model.setSelectedSplatOutputVariant(.original))
        let destination = fixture.base.appendingPathComponent("Captured.ply")
        try await model.exportCurrentSplat(source, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: fixture.subjectOutput.url))
        XCTAssertNotEqual(try Data(contentsOf: destination), try Data(contentsOf: fixture.originalURL))
    }

    func testVariantChangeDuringSubjectValidationRejectsCapturedSource() async throws {
        let fixture = try makePublicationFixture()
        defer { fixture.cleanup() }
        let validationStarted = DispatchSemaphore(value: 0)
        let allowValidation = DispatchSemaphore(value: 0)
        let state = PublicationArtifactState(.valid(fixture.subjectArtifact, fixture.subjectOutput))
        state.beforeLoad = {
            validationStarted.signal()
            _ = allowValidation.wait(timeout: .now() + 2)
        }
        let model = makeModel(fixture: fixture, artifactState: state)
        model.subjectOutput = fixture.subjectOutput
        XCTAssertTrue(model.setSelectedSplatOutputVariant(.subject))

        let validation = Task { @MainActor in
            do {
                _ = try await model.validatedCurrentSplatForPublication()
                return false
            } catch is CancellationError {
                return true
            } catch {
                XCTFail("Unexpected error: \(error)")
                return false
            }
        }
        let didStart = await wait(for: validationStarted)
        XCTAssertEqual(didStart, .success)

        XCTAssertTrue(model.setSelectedSplatOutputVariant(.original))
        allowValidation.signal()

        let wasCancelled = await validation.value
        XCTAssertTrue(wasCancelled)
    }

    func testSubjectShareSnapshotUsesCapturedIdentityAndFilename() async throws {
        let fixture = try makePublicationFixture()
        defer { fixture.cleanup() }
        let state = PublicationArtifactState(.valid(fixture.subjectArtifact, fixture.subjectOutput))
        let model = makeModel(fixture: fixture, artifactState: state)
        model.subjectOutput = fixture.subjectOutput
        XCTAssertTrue(model.setSelectedSplatOutputVariant(.subject))

        await model.prepareCurrentSplatForSharing()

        let prepared = try XCTUnwrap(model.test_preparedShareItem())
        defer { model.cancelSharing() }
        XCTAssertEqual(prepared.source.variant, .subject)
        XCTAssertEqual(prepared.source.outputURL, fixture.subjectOutput.url.standardizedFileURL)
        XCTAssertEqual(prepared.source.expectedIdentity, fixture.subjectIdentity)
        XCTAssertEqual(prepared.shareURL.lastPathComponent, "Project (Subject).ply")
        XCTAssertEqual(try Data(contentsOf: prepared.shareURL), try Data(contentsOf: fixture.subjectOutput.url))
    }

    func testPreparedSubjectShareInvalidatesWhenIsolationArtifactDisappears() async throws {
        let fixture = try makePublicationFixture()
        defer { fixture.cleanup() }
        let state = PublicationArtifactState(.valid(fixture.subjectArtifact, fixture.subjectOutput))
        let model = makeModel(fixture: fixture, artifactState: state)
        model.subjectOutput = fixture.subjectOutput
        XCTAssertTrue(model.setSelectedSplatOutputVariant(.subject))
        await model.prepareCurrentSplatForSharing()
        let prepared = try XCTUnwrap(model.test_preparedShareItem())
        let shareDirectory = prepared.shareDirectoryURL

        state.result = .noArtifact
        await model.presentPreparedShare(from: NSButton())

        XCTAssertNil(model.test_preparedShareItem())
        XCTAssertFalse(model.isShareReady)
        XCTAssertTrue(model.shareStatusIsError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shareDirectory.path))
    }

    func testOriginalSharePreparationRetainsCanonicalReceiptBehavior() async throws {
        let fixture = try makePublicationFixture()
        defer { fixture.cleanup() }
        let state = PublicationArtifactState(.noArtifact)
        let model = makeModel(fixture: fixture, artifactState: state)

        await model.prepareCurrentSplatForSharing()

        let prepared = try XCTUnwrap(model.test_preparedShareItem())
        defer { model.cancelSharing() }
        XCTAssertEqual(prepared.source.variant, .original)
        XCTAssertEqual(prepared.source.expectedIdentity, fixture.originalIdentity)
        XCTAssertEqual(prepared.shareURL.lastPathComponent, "Project.ply")
        XCTAssertTrue(model.isShareReady)
    }

    private func wait(for semaphore: DispatchSemaphore) async -> DispatchTimeoutResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: semaphore.wait(timeout: .now() + 1))
            }
        }
    }

    private func makeModel(
        fixture: PublicationFixture,
        artifactState: PublicationArtifactState
    ) -> AppModel {
        let model = AppModel(
            toolchainManager: PublicationTestToolchainManager(),
            projectBaseURL: fixture.base,
            subjectIsolationArtifactLoader: { _ in artifactState.load() },
            finishedOutputValidator: { _ in fixture.originalURL }
        )
        model.currentProjectURL = fixture.projectURL
        model.outputPlyURL = fixture.originalURL
        return model
    }

    private func makePublicationFixture(
        title: String = "Project"
    ) throws -> PublicationFixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EasySplat-publication-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        let projectURL = base.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        try writePly(to: paths.outputSplatURL, vertices: [[0, 0, 0]])
        try writePly(to: paths.isolatedOutputURL, vertices: [[1, 0, 0], [2, 0, 0]])

        let originalEvidence = try ProjectArtifactValidator.validatedPlyEvidence(
            at: paths.outputSplatURL
        )
        let subjectEvidence = try ProjectArtifactValidator.validatedPlyEvidence(
            at: paths.isolatedOutputURL
        )
        var metadata = ProjectMetadata(
            title: title,
            input: .video(files: []),
            requestedRunOptions: RequestedRunOptions(
                capturePath: .walkthrough,
                detailProfile: .balanced
            ),
            state: PipelineState(stage: .done, lastError: nil)
        )
        metadata.resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: metadata.requestedRunOptions,
            input: metadata.input,
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )
        let trainingArtifact = TrainingArtifact(
            trainerVersion: "test",
            runtimeVersion: "native-metal-cli-v2",
            trainerBuildDigest: String(repeating: "a", count: 64),
            inputDigest: String(repeating: "b", count: 64),
            geometryDigest: String(repeating: "c", count: 64),
            datasetDerivation: makeAppTestMsplatDatasetDerivation(),
            detailProfile: .balanced,
            iterationLimit: 7_000,
            plateauWindow: 800,
            cameraOrderSeed: 42,
            completedIteration: 7_000,
            checkpointPath: nil,
            checkpointDigest: nil,
            outputPath: "Output/splat.ply",
            outputSHA256: originalEvidence.sha256,
            outputBytes: Int64(originalEvidence.byteCount),
            gaussianCount: originalEvidence.vertexCount,
            elapsedSeconds: 1,
            peakMemoryBytes: 1,
            memoryBudgetBytes: 1,
            resourceAdmission: makeAppTestTrainingResourceAdmission(),
            rasterFallbackCount: 0,
            rasterExactFallbackElapsedSeconds: 0,
            rasterExactBufferGrowthCount: 0,
            rasterExactBufferBytesAdded: 0,
            rasterReplayElapsedSeconds: 0,
            rasterPeakExactIntersectionCapacity: 0,
            droppedIntersectionCount: 0,
            sceneBounds: originalEvidence.sceneBounds,
            completionStatus: .completed
        )
        try persistCompletedAppTestArtifacts(
            metadata: metadata,
            paths: paths,
            trainingArtifact: trainingArtifact
        )

        let subjectOutput = ValidatedSplatOutput(
            variant: .subject,
            url: paths.isolatedOutputURL,
            sha256: subjectEvidence.sha256,
            byteCount: subjectEvidence.byteCount,
            gaussianCount: subjectEvidence.vertexCount,
            sceneBounds: subjectEvidence.sceneBounds
        )
        return PublicationFixture(
            base: base,
            projectURL: projectURL,
            paths: paths,
            originalURL: paths.outputSplatURL,
            originalIdentity: ExpectedPlyArtifactIdentity(
                byteCount: originalEvidence.byteCount,
                vertexCount: originalEvidence.vertexCount,
                sha256: originalEvidence.sha256
            ),
            subjectOutput: subjectOutput,
            subjectIdentity: ExpectedPlyArtifactIdentity(
                byteCount: subjectEvidence.byteCount,
                vertexCount: subjectEvidence.vertexCount,
                sha256: subjectEvidence.sha256
            ),
            subjectArtifact: makePublicationIsolationArtifact(output: subjectOutput)
        )
    }

    private func writePly(to url: URL, vertices: [[Float]]) throws {
        let rows = vertices.map { "\($0[0]) \($0[1]) \($0[2]) 1 1 1 -4 -4 -4 1 1 0 0 0" }
            .joined(separator: "\n")
        let text = """
        ply
        format ascii 1.0
        element vertex \(vertices.count)
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
        \(rows)
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }
}

private struct PublicationFixture {
    let base: URL
    let projectURL: URL
    let paths: ProjectPaths
    let originalURL: URL
    let originalIdentity: ExpectedPlyArtifactIdentity
    let subjectOutput: ValidatedSplatOutput
    let subjectIdentity: ExpectedPlyArtifactIdentity
    let subjectArtifact: IsolationArtifact

    func cleanup() {
        try? FileManager.default.removeItem(at: base)
    }
}

private final class PublicationArtifactState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedResult: IsolationArtifactLoadResult
    var beforeLoad: (@Sendable () -> Void)?

    init(_ result: IsolationArtifactLoadResult) {
        storedResult = result
    }

    var result: IsolationArtifactLoadResult {
        get { lock.withLock { storedResult } }
        set { lock.withLock { storedResult = newValue } }
    }

    func load() -> IsolationArtifactLoadResult {
        beforeLoad?()
        return result
    }
}

private struct PublicationTestToolchainManager: ToolchainManaging {
    func resolveToolchain(
        request: ToolchainCapabilityRequest,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        fatalError("Publication tests do not install a toolchain.")
    }
}

private func makePublicationIsolationArtifact(
    output: ValidatedSplatOutput
) -> IsolationArtifact {
    IsolationArtifact(
        sourcePlySHA256: String(repeating: "1", count: 64),
        trainingManifestSHA256: String(repeating: "2", count: 64),
        dataset: .init(
            inputDigest: String(repeating: "3", count: 64),
            geometryDigest: String(repeating: "4", count: 64),
            selectedFramesDigest: String(repeating: "5", count: 64),
            selectedImageOrder: []
        ),
        masks: [],
        toolchainBuildIdentity: "test",
        nativeExecutableSHA256: String(repeating: "6", count: 64),
        visionRequestRevision: 1,
        selectedViewIdentities: [],
        heldOutViewIdentities: [],
        policy: .init(
            version: 1,
            minimumMaskConfidence: 0.8,
            minimumHeldOutMedianIoU: 0.6,
            minimumHeldOutFirstQuartileIoU: 0.5,
            minimumRetainedGaussianFraction: 0.01,
            maximumRetainedGaussianFraction: 0.95
        ),
        subjectAnchor: nil,
        metrics: .init(
            meanMaskConfidence: 0.9,
            heldOutMeanIoU: nil,
            heldOutMedianIoU: nil,
            heldOutFirstQuartileIoU: nil,
            retainedGaussianFraction: 0.5
        ),
        output: .init(
            identity: UUID(),
            relativePath: "Output/isolated.ply",
            sha256: output.sha256,
            byteCount: output.byteCount,
            gaussianCount: output.gaussianCount,
            sceneBounds: output.sceneBounds
        )
    )
}
