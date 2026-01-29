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
}

final class MockToolchainManager: ToolchainManaging {
    func ensureToolchain(
        manifestURL: URL,
        publicKeyBase64: String,
        targetName: String,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        return ToolchainPaths(
            root: URL(fileURLWithPath: "/tmp/toolchain"),
            colmap: URL(fileURLWithPath: "/mock/colmap"),
            glomap: URL(fileURLWithPath: "/mock/glomap"),
            brush: URL(fileURLWithPath: "/mock/brush")
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
