import EasySplatCore
import Foundation
import XCTest
@testable import EasySplatApp

final class ResultWorkspaceTests: XCTestCase {
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
    func testExportCopiesOnlyAValidatedFinishedPly() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(in: base, validOutput: true)
        let model = AppModel(toolchainManager: ResultTestToolchainManager(), projectBaseURL: base)
        model.currentProjectURL = projectURL

        let destination = base.appendingPathComponent("Exported.ply")
        try model.exportCurrentSplat(to: destination)

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
    func testInvalidExportNeverReplacesExistingDestination() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(in: base, validOutput: false)
        let model = AppModel(toolchainManager: ResultTestToolchainManager(), projectBaseURL: base)
        model.currentProjectURL = projectURL

        let destination = base.appendingPathComponent("Keep Me.ply")
        let original = Data("existing destination".utf8)
        try original.write(to: destination)

        XCTAssertThrowsError(try model.exportCurrentSplat(to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    @MainActor
    func testValidPlyFromUnfinishedProjectIsNotExportable() throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let projectURL = try makeFinishedProject(in: base, validOutput: true, stage: .trainSplat)
        let model = AppModel(toolchainManager: ResultTestToolchainManager(), projectBaseURL: base)
        model.currentProjectURL = projectURL

        let destination = base.appendingPathComponent("Must Not Exist.ply")
        XCTAssertThrowsError(try model.exportCurrentSplat(to: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("EasySplat-result-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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
            preset: PresetSpec(mode: .room, quality: .standard),
            state: PipelineState(stage: stage, attempt: 0, lastError: nil, resumeToken: nil),
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

private struct ResultTestToolchainManager: ToolchainManaging {
    func ensureToolchain(
        manifestURL: URL,
        publicKeyBase64: String,
        targetName: String,
        request: ToolchainCapabilityRequest,
        onProgress: @escaping @Sendable (Double, String) -> Void
    ) async throws -> ToolchainPaths {
        fatalError("Result workspace tests do not install a toolchain")
    }
}
