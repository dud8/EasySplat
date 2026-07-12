import XCTest
@testable import EasySplatCore

final class AutoTunerTests: XCTestCase {
    func testLowTierOverrides() throws {
        let profile = HardwareProfile(memoryGB: 16.0, cpuCount: 10, gpuWorkingSetGB: 8.0)
        let tune = AutoTuner.make(
            profile: profile,
            preset: PresetSpec(mode: .object, quality: .standard),
            selectedFrameCount: 200
        )
        XCTAssertEqual(tune.tier, .low)
        XCTAssertEqual(tune.colmapMaxNumFeatures, 4_096)
        XCTAssertEqual(tune.colmapMaxNumMatches, 4_096)
        XCTAssertEqual(tune.sequentialOverlap, 8)
        XCTAssertEqual(tune.exhaustiveBlockSize, 10)
        XCTAssertEqual(tune.threadCap, 4)
        XCTAssertEqual(tune.colmapMaxImageSizeCap, 1200)
    }

    func testMidTierOverrides() throws {
        let profile = HardwareProfile(memoryGB: 32.0, cpuCount: 12, gpuWorkingSetGB: 12.0)
        let tune = AutoTuner.make(
            profile: profile,
            preset: PresetSpec(mode: .object, quality: .standard),
            selectedFrameCount: 200
        )
        XCTAssertEqual(tune.tier, .mid)
        XCTAssertEqual(tune.colmapMaxNumFeatures, 8_192)
        XCTAssertEqual(tune.colmapMaxNumMatches, 8_192)
        XCTAssertEqual(tune.sequentialOverlap, 10)
        XCTAssertEqual(tune.exhaustiveBlockSize, 20)
        XCTAssertEqual(tune.threadCap, 6)
        XCTAssertNil(tune.colmapMaxImageSizeCap)
    }

    func testHighTierOverrides() throws {
        let profile = HardwareProfile(memoryGB: 48.0, cpuCount: 16, gpuWorkingSetGB: 24.0)
        let tune = AutoTuner.make(
            profile: profile,
            preset: PresetSpec(mode: .object, quality: .standard),
            selectedFrameCount: 200
        )
        XCTAssertEqual(tune.tier, .high)
        XCTAssertEqual(tune.colmapMaxNumFeatures, 10_000)
        XCTAssertEqual(tune.colmapMaxNumMatches, 10_000)
        XCTAssertEqual(tune.sequentialOverlap, 12)
        XCTAssertEqual(tune.exhaustiveBlockSize, 25)
        XCTAssertEqual(tune.threadCap, 8)
        XCTAssertNil(tune.colmapMaxImageSizeCap)
    }

}
