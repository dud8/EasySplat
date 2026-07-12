import EasySplatCore
import Foundation
import MetalKit
import XCTest
@testable import EasySplatApp

final class ResultWorkspaceTests: XCTestCase {
    func testPhotoSelectionFactAppearsOnlyForInputsContainingPhotos() {
        XCTAssertFalse(ViewerView.inputContainsPhotos(.video(files: ["/tmp/a.mov"])))
        XCTAssertTrue(ViewerView.inputContainsPhotos(.photos(folder: "/tmp/photos")))
        XCTAssertTrue(ViewerView.inputContainsPhotos(.mixed(videos: ["/tmp/a.mov"], photosFolder: "/tmp/photos")))
        XCTAssertFalse(ViewerView.inputContainsPhotos(nil))
    }

    func testViewerKeyboardCommandsMapWithoutHijackingSystemShortcuts() {
        XCTAssertEqual(
            ViewerKeyboardCommand.resolve(keyCode: 123, characters: nil, modifiers: []),
            .orbit(horizontal: -1, vertical: 0)
        )
        XCTAssertEqual(
            ViewerKeyboardCommand.resolve(keyCode: 126, characters: nil, modifiers: []),
            .orbit(horizontal: 0, vertical: 1)
        )
        XCTAssertEqual(
            ViewerKeyboardCommand.resolve(keyCode: 124, characters: nil, modifiers: [.option]),
            .pan(horizontal: 1, vertical: 0)
        )
        XCTAssertEqual(
            ViewerKeyboardCommand.resolve(keyCode: 125, characters: nil, modifiers: [.option]),
            .pan(horizontal: 0, vertical: -1)
        )
        XCTAssertEqual(
            ViewerKeyboardCommand.resolve(keyCode: 24, characters: "+", modifiers: [.shift]),
            .zoomIn
        )
        XCTAssertEqual(
            ViewerKeyboardCommand.resolve(keyCode: 27, characters: "-", modifiers: []),
            .zoomOut
        )
        XCTAssertEqual(
            ViewerKeyboardCommand.resolve(keyCode: 3, characters: "f", modifiers: []),
            .fit
        )
        XCTAssertEqual(
            ViewerKeyboardCommand.resolve(keyCode: 15, characters: "R", modifiers: [.shift]),
            .reset
        )

        XCTAssertNil(ViewerKeyboardCommand.resolve(keyCode: 3, characters: "f", modifiers: [.command]))
        XCTAssertNil(ViewerKeyboardCommand.resolve(keyCode: 3, characters: "f", modifiers: [.option]))
        XCTAssertNil(ViewerKeyboardCommand.resolve(keyCode: 49, characters: " ", modifiers: []))
    }

    @MainActor
    func testApplyingNewBoundsClearsPriorPan() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: .zero, device: device)
        let renderer = try XCTUnwrap(MetalKitSceneRenderer(view))

        renderer.pan(deltaX: 12, deltaY: -7)
        XCTAssertNotEqual(renderer.pan, .zero)

        renderer.applyBounds(center: SIMD3<Float>(1, 2, 3), radius: 4)

        XCTAssertEqual(renderer.pan, .zero)
    }

    @MainActor
    func testViewerBoundsIgnoreAnOlderRequestThatFinishesLast() async {
        let loader = ControlledBoundsLoader()
        let controller = SplatViewerController(boundsLoader: { url in
            await loader.load(url)
        })
        let oldURL = URL(fileURLWithPath: "/tmp/old.ply")
        let newURL = URL(fileURLWithPath: "/tmp/new.ply")
        let firstRequest = PreviewLoadRequest(url: oldURL, reloadToken: 0)

        controller.prepareBounds(for: firstRequest)
        controller.startBoundsLoad(for: firstRequest)
        await loader.waitUntilRequested(oldURL)
        await loader.complete(
            oldURL,
            with: (center: SIMD3<Float>(1, 2, 3), radius: 4)
        )
        await waitForBounds(on: controller, center: SIMD3<Float>(1, 2, 3))

        let staleRequest = PreviewLoadRequest(url: oldURL, reloadToken: 1)
        controller.prepareBounds(for: staleRequest)
        controller.startBoundsLoad(for: staleRequest)
        await loader.waitUntilRequested(oldURL)
        XCTAssertNil(controller.currentBounds)

        let currentRequest = PreviewLoadRequest(url: newURL, reloadToken: 0)
        controller.prepareBounds(for: currentRequest)
        controller.startBoundsLoad(for: currentRequest)
        await loader.waitUntilRequested(newURL)
        await loader.complete(
            newURL,
            with: (center: SIMD3<Float>(7, 8, 9), radius: 10)
        )
        await waitForBounds(on: controller, center: SIMD3<Float>(7, 8, 9))

        await loader.complete(
            oldURL,
            with: (center: SIMD3<Float>(40, 50, 60), radius: 70)
        )
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertEqual(controller.currentBounds?.center, SIMD3<Float>(7, 8, 9))
        XCTAssertEqual(controller.currentBounds?.radius, 10)
    }

    @MainActor
    func testExportCopiesOnlyAValidatedFinishedPly() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(in: base, validOutput: true)
        let model = AppModel(toolchainManager: ResultTestToolchainManager(), projectBaseURL: base)
        model.currentProjectURL = projectURL

        let destination = base.appendingPathComponent("Exported.ply")
        try await model.exportCurrentSplat(to: destination)

        XCTAssertEqual(
            ProjectArtifactValidator.validatePlyFile(at: destination),
            .valid
        )
        XCTAssertEqual(
            try Data(contentsOf: destination),
            try Data(contentsOf: ProjectPaths(root: projectURL).outputURL.appendingPathComponent("splat.ply"))
        )
    }

    @MainActor
    func testFinishedOutputValidationRunsOutsideTheMainThread() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(in: base, validOutput: true)
        let outputURL = ProjectPaths(root: projectURL).outputURL.appendingPathComponent("splat.ply")
        let observation = ThreadObservation()
        let model = AppModel(
            toolchainManager: ResultTestToolchainManager(),
            projectBaseURL: base,
            finishedOutputValidator: { requestedProjectURL in
                observation.record(isMainThread: Thread.isMainThread)
                return requestedProjectURL.standardizedFileURL == projectURL.standardizedFileURL
                    ? outputURL
                    : nil
            }
        )
        model.currentProjectURL = projectURL

        let validatedURL = try await model.validatedCurrentSplatForExport()

        XCTAssertEqual(validatedURL.standardizedFileURL, outputURL.standardizedFileURL)
        XCTAssertEqual(observation.wasMainThread, false)
    }

    @MainActor
    func testInvalidExportNeverReplacesExistingDestination() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(in: base, validOutput: false)
        let model = AppModel(toolchainManager: ResultTestToolchainManager(), projectBaseURL: base)
        model.currentProjectURL = projectURL

        let destination = base.appendingPathComponent("Keep Me.ply")
        let original = Data("existing destination".utf8)
        try original.write(to: destination)

        do {
            try await model.exportCurrentSplat(to: destination)
            XCTFail("Expected invalid output to be rejected")
        } catch {
            // Expected.
        }
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    @MainActor
    func testValidPlyFromUnfinishedProjectIsNotExportable() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(in: base, validOutput: true, stage: .trainSplat)
        let model = AppModel(toolchainManager: ResultTestToolchainManager(), projectBaseURL: base)
        model.currentProjectURL = projectURL

        let destination = base.appendingPathComponent("Must Not Exist.ply")
        do {
            try await model.exportCurrentSplat(to: destination)
            XCTFail("Expected unfinished output to be rejected")
        } catch {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor
    func testBeginNewSplatClearsTheCurrentResultAndPendingInput() {
        let model = AppModel(toolchainManager: ResultTestToolchainManager())
        model.viewState = .viewer
        model.currentProjectURL = URL(fileURLWithPath: "/tmp/Old.easysplatproj")
        model.outputPlyURL = URL(fileURLWithPath: "/tmp/Old.easysplatproj/Output/splat.ply")
        model.pendingVideoURLs = [URL(fileURLWithPath: "/tmp/new.mov")]
        var selectedProjectURL: URL? = model.currentProjectURL

        RootView.prepareNewSplat(model: model, selectedProjectURL: &selectedProjectURL)

        XCTAssertEqual(model.viewState, .home)
        XCTAssertNil(model.currentProjectURL)
        XCTAssertNil(model.outputPlyURL)
        XCTAssertTrue(model.pendingVideoURLs.isEmpty)
        XCTAssertNil(selectedProjectURL)
    }

    @MainActor
    func testBackToProjectsClearsTheCurrentProjectAndSelectionButKeepsPendingInput() {
        let model = AppModel(toolchainManager: ResultTestToolchainManager())
        let pendingInput = URL(fileURLWithPath: "/tmp/retry.mov")
        model.viewState = .processing
        model.currentProjectURL = URL(fileURLWithPath: "/tmp/Failed.easysplatproj")
        model.lastError = "Capture failed"
        model.pendingVideoURLs = [pendingInput]
        var selectedProjectURL: URL? = model.currentProjectURL

        RootView.prepareProjectList(model: model, selectedProjectURL: &selectedProjectURL)

        XCTAssertEqual(model.viewState, .home)
        XCTAssertNil(model.currentProjectURL)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.pendingVideoURLs, [pendingInput])
        XCTAssertNil(selectedProjectURL)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EasySplat-result-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    private func waitForBounds(
        on controller: SplatViewerController,
        center: SIMD3<Float>
    ) async {
        for _ in 0..<100 {
            if controller.currentBounds?.center == center {
                return
            }
            await Task.yield()
        }
        XCTFail("Timed out waiting for viewer bounds")
    }

    private func makeFinishedProject(
        in base: URL,
        validOutput: Bool,
        stage: PipelineStage = .done
    ) throws -> URL {
        let projectURL = base.appendingPathComponent("Result.easysplatproj", isDirectory: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let outputURL = paths.outputURL.appendingPathComponent("splat.ply")
        if validOutput {
            try writeResultPly(to: outputURL)
        } else {
            try Data("not a ply".utf8).write(to: outputURL)
        }
        let metadata = ProjectMetadata(
            title: "Result",
            input: .photos(folder: "/tmp/photos"),
            requestedRunOptions: RequestedRunOptions(capturePath: .walkthrough, detailProfile: .balanced),
            state: PipelineState(stage: stage, lastError: nil),
            outputs: OutputSpec(
                splatPlyPath: "Output/splat.ply",
                colmapModelPath: "SfM/colmap/sparse/0"
            )
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        return projectURL
    }

    private func writeResultPly(to url: URL) throws {
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
        0 0 0 1 1 1 -4 -4 -4 1 1 0 0 0
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

private actor ControlledBoundsLoader {
    typealias Bounds = SplatViewerController.Bounds

    private var continuations: [URL: CheckedContinuation<Bounds?, Never>] = [:]
    private var requestWaiters: [URL: [CheckedContinuation<Void, Never>]] = [:]

    func load(_ url: URL) async -> Bounds? {
        await withCheckedContinuation { continuation in
            continuations[url] = continuation
            let waiters = requestWaiters.removeValue(forKey: url) ?? []
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    func waitUntilRequested(_ url: URL) async {
        guard continuations[url] == nil else { return }
        await withCheckedContinuation { continuation in
            requestWaiters[url, default: []].append(continuation)
        }
    }

    func complete(_ url: URL, with bounds: Bounds?) {
        continuations.removeValue(forKey: url)?.resume(returning: bounds)
    }
}

private final class ThreadObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    var wasMainThread: Bool? {
        lock.withLock { value }
    }

    func record(isMainThread: Bool) {
        lock.withLock {
            value = isMainThread
        }
    }
}

private struct ResultTestToolchainManager: ToolchainManaging {
    func ensureToolchain(
        manifestURL: URL,
        publicKeyBase64: String,
        request: ToolchainCapabilityRequest,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        fatalError("Result workspace tests do not install a toolchain")
    }
}
