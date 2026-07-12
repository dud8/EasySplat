import XCTest
@testable import EasySplatCore

final class BlurFilterTests: XCTestCase {
    private func makeRunner() -> PipelineRunner {
        let root = URL(fileURLWithPath: "/tmp")
        let toolchain = TestToolchains.toolchainPaths(root: root)
        let config = PipelineRunner.PipelineConfig(toolchain: toolchain, preset: PresetSpec(mode: .object, quality: .standard))
        return PipelineRunner(projectURL: root, config: config)
    }

    private func makeURLs(_ count: Int) -> [URL] {
        (0..<count).map { URL(fileURLWithPath: "/tmp/frame_\($0).jpg") }
    }

    func testBlurFilterKeepsAllWhenAboveFloor() {
        let runner = makeRunner()
        let frames = makeURLs(10)
        var sharpness: [URL: Double] = [:]
        for url in frames {
            sharpness[url] = 25.0
        }
        let result = runner.test_filterVeryBlurryVideoFrames(
            frames: frames,
            sharpnessByFrame: sharpness,
            sharpnessFloor: 40.0,
            maxDropFraction: 0.2,
            floorScale: 0.5
        )
        XCTAssertEqual(result.dropped, 0)
        XCTAssertEqual(result.frames, frames)
    }

    func testBlurFilterDropsOnlyBelowFloorWhenWithinCap() {
        let runner = makeRunner()
        let frames = makeURLs(10)
        var sharpness: [URL: Double] = [:]
        for (index, url) in frames.enumerated() {
            sharpness[url] = index < 2 ? 5.0 : 30.0
        }
        let result = runner.test_filterVeryBlurryVideoFrames(
            frames: frames,
            sharpnessByFrame: sharpness,
            sharpnessFloor: 40.0,
            maxDropFraction: 0.5,
            floorScale: 0.5
        )
        XCTAssertEqual(result.dropped, 2)
        XCTAssertEqual(result.frames.count, 8)
        XCTAssertFalse(result.frames.contains(frames[0]))
        XCTAssertFalse(result.frames.contains(frames[1]))
    }

    func testBlurFilterCapsAtMaxDropFraction() {
        let runner = makeRunner()
        let frames = makeURLs(10)
        var sharpness: [URL: Double] = [:]
        for (index, url) in frames.enumerated() {
            sharpness[url] = index < 6 ? Double(index + 1) : 30.0
        }
        let result = runner.test_filterVeryBlurryVideoFrames(
            frames: frames,
            sharpnessByFrame: sharpness,
            sharpnessFloor: 40.0,
            maxDropFraction: 0.25,
            floorScale: 0.5
        )
        XCTAssertEqual(result.dropped, 2)
        XCTAssertEqual(result.frames.count, 8)
        XCTAssertFalse(result.frames.contains(frames[0]))
        XCTAssertFalse(result.frames.contains(frames[1]))
    }
}
