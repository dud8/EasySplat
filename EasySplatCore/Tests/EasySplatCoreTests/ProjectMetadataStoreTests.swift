import XCTest
@testable import EasySplatCore

final class ProjectMetadataStoreTests: XCTestCase {
    func testRoundTripMetadata() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("project.json")

        let state = PipelineState(stage: .sfmMatching, attempt: 2, lastError: "boom", resumeToken: "token")
        let output = OutputSpec(splatPlyPath: "Output/splat.ply", colmapModelPath: "SfM/colmap/sparse/0")
        let metadata = ProjectMetadata(
            formatVersion: 2,
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 123456),
            title: "Test",
            input: .mixed(videos: ["/tmp/a.mov"], photosFolder: "/tmp/photos"),
            preset: PresetSpec(mode: .room, quality: .ultra),
            state: state,
            outputs: output
        )

        try ProjectMetadataStore.save(metadata, to: url)
        let loaded = try ProjectMetadataStore.load(from: url)

        XCTAssertEqual(loaded.formatVersion, metadata.formatVersion)
        XCTAssertEqual(loaded.id, metadata.id)
        XCTAssertEqual(loaded.createdAt, metadata.createdAt)
        XCTAssertEqual(loaded.title, metadata.title)
        XCTAssertEqual(loaded.preset.mode, metadata.preset.mode)
        XCTAssertEqual(loaded.preset.quality, metadata.preset.quality)
        XCTAssertEqual(loaded.state.stage, metadata.state.stage)
        XCTAssertEqual(loaded.state.attempt, metadata.state.attempt)
        XCTAssertEqual(loaded.state.lastError, metadata.state.lastError)
        XCTAssertEqual(loaded.state.resumeToken, metadata.state.resumeToken)
        XCTAssertEqual(loaded.outputs?.splatPlyPath, metadata.outputs?.splatPlyPath)
        XCTAssertEqual(loaded.outputs?.colmapModelPath, metadata.outputs?.colmapModelPath)
    }
}
