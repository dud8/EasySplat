#if canImport(XCTest)
import Foundation
import XCTest
@testable import EasySplatApp
@testable import EasySplatCore

@MainActor
final class AppModelTests: XCTestCase {
    func testStartProjectTransitionsToViewer() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let input = tempBase.appendingPathComponent("input.mov")
        try Data("video".utf8).write(to: input)

        let mockToolchain = MockToolchainManager()
        let model = AppModel(
            toolchainManager: mockToolchain,
            projectBaseURL: tempBase
        ) { projectURL, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        model.addInputs(urls: [input])
        model.startFromPendingSelection()

        try await waitForViewState(model: model, state: .viewer)

        XCTAssertEqual(model.viewState, .viewer)
        XCTAssertNotNil(model.currentProjectURL)
        XCTAssertNotNil(model.outputPlyURL)
        guard let projectURL = model.currentProjectURL else {
            XCTFail("Missing project URL")
            return
        }
        let metadataURL = projectURL.appendingPathComponent("project.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadataURL.path))
    }

    func testAddInputsIgnoresNonVideoAndClearsWarning() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let video = tempBase.appendingPathComponent("input.mov")
        let text = tempBase.appendingPathComponent("note.txt")
        try? Data("video".utf8).write(to: video)
        try? Data("text".utf8).write(to: text)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }

        model.addInputs(urls: [video, text])
        XCTAssertEqual(model.pendingVideoURLs.count, 1)
        XCTAssertNotNil(model.selectionWarning)

        model.addInputs(urls: [video])
        XCTAssertNil(model.selectionWarning)
    }

    func testAddInputsDeduplicatesVideos() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let video = tempBase.appendingPathComponent("input.mov")
        try? Data("video".utf8).write(to: video)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }

        model.addInputs(urls: [video])
        model.addInputs(urls: [video])
        XCTAssertEqual(model.pendingVideoURLs.count, 1)
    }

    func testStartFromPendingSelectionWithNoInputsDoesNothing() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }
        model.startFromPendingSelection()
        XCTAssertEqual(model.viewState, .home)
    }

    func testResumeProjectShortCircuitsWhenOutputExists() async throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()
        let output = paths.outputURL.appendingPathComponent("splat.ply")
        try FileManager.default.createDirectory(at: paths.outputURL, withIntermediateDirectories: true)
        try Data("ply".utf8).write(to: output)

        let metadata = ProjectMetadata(
            title: "Project",
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard),
            state: PipelineState(stage: .done, attempt: 0, lastError: nil, resumeToken: nil),
            outputs: OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        model.resumeProject(at: projectURL)
        try await waitForViewState(model: model, state: .viewer)
        XCTAssertEqual(model.viewState, .viewer)
        XCTAssertEqual(model.outputPlyURL, output)
    }

    func testLoadPipelineLogTailWithInvalidUtf8() throws {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
        let projectURL = tempBase.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: projectURL)
        try paths.ensureDirectories()

        var logData = Data([0xF0, 0x9F])
        logData.append(contentsOf: "Hello log\n".utf8)
        try logData.write(to: paths.pipelineLogURL, options: [.atomic])

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: projectURL, config: config)
        }

        let lines = model.test_loadPipelineLogTail(projectURL: projectURL)
        XCTAssertTrue(lines.contains { $0.contains("Hello log") })
    }

    func testRefreshProjectSummariesStatusMapping() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let readyURL = try makeProject(at: base, name: "Ready", lastError: nil, withOutput: true)
        _ = readyURL
        let failedURL = try makeProject(at: base, name: "Failed", lastError: "boom", withOutput: false)
        _ = failedURL
        let inProgressURL = try makeProject(at: base, name: "Progress", lastError: nil, withOutput: false)
        _ = inProgressURL

        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: base) { _, config in
            MockPipelineRunner(projectURL: base, config: config)
        }
        model.refreshProjectSummaries()

        let statusByTitle = Dictionary(model.projectSummaries.map { ($0.title, $0.status) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(statusByTitle["Ready"], .ready)
        XCTAssertEqual(statusByTitle["Failed"], .failed)
        XCTAssertEqual(statusByTitle["Progress"], .inProgress)
    }

    func testErrorDetailsTextCombinesFields() {
        let tempBase = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let model = AppModel(toolchainManager: MockToolchainManager(), projectBaseURL: tempBase) { _, config in
            MockPipelineRunner(projectURL: tempBase, config: config)
        }
        model.statusDetail = "detail"
        model.errorDetails = "error"
        model.logLines = ["a", "b"]

        let text = model.errorDetailsText ?? ""
        XCTAssertTrue(text.contains("detail"))
        XCTAssertTrue(text.contains("error"))
        XCTAssertTrue(text.contains("Logs:"))
    }

    private func waitForViewState(model: AppModel, state: AppModel.ViewState, timeout: TimeInterval = 2.0) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if model.viewState == state {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for viewState to become \(state)")
    }

    private func makeProject(at base: URL, name: String, lastError: String?, withOutput: Bool) throws -> URL {
        let url = base.appendingPathComponent("\(name).easysplatproj", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let paths = ProjectPaths(root: url)
        try paths.ensureDirectories()
        if withOutput {
            try FileManager.default.createDirectory(at: paths.outputURL, withIntermediateDirectories: true)
            try Data("ply".utf8).write(to: paths.outputURL.appendingPathComponent("splat.ply"))
        }
        let metadata = ProjectMetadata(
            title: name,
            input: .photos(folder: "/tmp/photos"),
            preset: PresetSpec(mode: .object, quality: .standard),
            state: PipelineState(stage: .done, attempt: 0, lastError: lastError, resumeToken: nil),
            outputs: withOutput ? OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0") : nil
        )
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
        return url
    }
}

final class MockToolchainManager: ToolchainManaging {
    func ensureToolchain(
        manifestURL: URL,
        publicKeyBase64: String,
        targetName: String,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        let vggt = VggtToolchain(
            root: URL(fileURLWithPath: "/mock/vggt_mps"),
            sfmTool: URL(fileURLWithPath: "/mock/vggt_mps/bin/easysplat_vggt_sfm"),
            python: URL(fileURLWithPath: "/mock/vggt_mps/python/bin/python3"),
            models: URL(fileURLWithPath: "/mock/vggt_mps/models")
        )
        return ToolchainPaths(
            root: URL(fileURLWithPath: "/tmp/toolchain"),
            colmap: URL(fileURLWithPath: "/mock/colmap"),
            glomap: URL(fileURLWithPath: "/mock/glomap"),
            brush: URL(fileURLWithPath: "/mock/brush"),
            vggt: vggt
        )
    }
}

final class MockPipelineRunner: PipelineRunning {
    private let projectURL: URL
    private let config: PipelineRunner.PipelineConfig

    init(projectURL: URL, config: PipelineRunner.PipelineConfig) {
        self.projectURL = projectURL
        self.config = config
    }

    func run(resumeFrom lastCompletedStage: PipelineStage?, events: @escaping @Sendable (PipelineEvent) -> Void) async throws {
        events(.stageStarted(stage: .importInput))
        events(.stageFinished(stage: .importInput))

        let paths = ProjectPaths(root: projectURL)
        var metadata = try ProjectMetadataStore.load(from: paths.metadataURL)
        let outputURL = paths.outputURL.appendingPathComponent("splat.ply")
        try FileManager.default.createDirectory(at: paths.outputURL, withIntermediateDirectories: true)
        try Data("ply".utf8).write(to: outputURL)
        metadata.outputs = OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
        metadata.state = PipelineState(stage: .done, attempt: 0, lastError: nil, resumeToken: nil)
        try ProjectMetadataStore.save(metadata, to: paths.metadataURL)
    }
}
#endif
