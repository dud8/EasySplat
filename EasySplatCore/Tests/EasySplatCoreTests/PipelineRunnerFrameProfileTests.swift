#if canImport(XCTest)
import XCTest
@testable import EasySplatCore

final class PipelineRunnerFrameProfileTests: XCTestCase {
    func testBalancedVideoUsesPersistedAnalysisFrameRate() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = PipelineRunner(
            projectURL: root,
            config: .init(toolchain: TestToolchains.toolchainPaths(root: root))
        )
        let plan = RunPlanResolver.resolve(
            requestedOptions: RequestedRunOptions(detailProfile: .balanced),
            input: .video(files: ["/tmp/clip.mov"]),
            hardware: HardwareProfile(memoryGB: 48, cpuCount: 16, gpuWorkingSetGB: 36),
            developmentOverrides: .none
        )

        let profile = runner.frameExtractionProfile(for: plan, detail: .balanced)

        XCTAssertEqual(plan.analysisFrameRate, 3)
        XCTAssertEqual(profile.targetFPS, plan.analysisFrameRate)
    }
}
#endif
