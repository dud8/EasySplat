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
        XCTAssertEqual(tune.mapAnythingResolution, 518)
        XCTAssertEqual(tune.mapAnythingDirectViewLimit, 0)
        XCTAssertEqual(tune.mapAnythingAnchorMaxViews, 24)
        XCTAssertEqual(tune.mapAnythingWindowSize, 4)
        XCTAssertEqual(tune.mapAnythingWindowOverlap, 1)
        XCTAssertEqual(tune.vggtImageLoadResolution, 768)
        XCTAssertEqual(tune.vggtFixedResolution, 448)
        XCTAssertEqual(tune.vggtMaxPoints, 60_000)
        XCTAssertEqual(tune.colmapMaxNumFeatures, 4_096)
        XCTAssertEqual(tune.colmapMaxNumMatches, 4_096)
        XCTAssertEqual(tune.sequentialOverlap, 8)
        XCTAssertEqual(tune.exhaustiveBlockSize, 10)
        XCTAssertEqual(tune.threadCap, 4)
        XCTAssertEqual(tune.colmapMaxImageSizeCap, 1200)
        XCTAssertTrue(tune.vggtAllowed)
    }

    func testMidTierOverrides() throws {
        let profile = HardwareProfile(memoryGB: 32.0, cpuCount: 12, gpuWorkingSetGB: 12.0)
        let tune = AutoTuner.make(
            profile: profile,
            preset: PresetSpec(mode: .object, quality: .standard),
            selectedFrameCount: 200
        )
        XCTAssertEqual(tune.tier, .mid)
        XCTAssertEqual(tune.mapAnythingResolution, 518)
        XCTAssertEqual(tune.mapAnythingDirectViewLimit, 6)
        XCTAssertEqual(tune.mapAnythingAnchorMaxViews, 48)
        XCTAssertEqual(tune.mapAnythingWindowSize, 6)
        XCTAssertEqual(tune.mapAnythingWindowOverlap, 2)
        XCTAssertEqual(tune.vggtImageLoadResolution, 1024)
        XCTAssertEqual(tune.vggtFixedResolution, 518)
        XCTAssertEqual(tune.vggtMaxPoints, 100_000)
        XCTAssertEqual(tune.colmapMaxNumFeatures, 8_192)
        XCTAssertEqual(tune.colmapMaxNumMatches, 8_192)
        XCTAssertEqual(tune.sequentialOverlap, 10)
        XCTAssertEqual(tune.exhaustiveBlockSize, 20)
        XCTAssertEqual(tune.threadCap, 6)
        XCTAssertNil(tune.colmapMaxImageSizeCap)
        XCTAssertTrue(tune.vggtAllowed)
    }

    func testHighTierOverrides() throws {
        let profile = HardwareProfile(memoryGB: 48.0, cpuCount: 16, gpuWorkingSetGB: 24.0)
        let tune = AutoTuner.make(
            profile: profile,
            preset: PresetSpec(mode: .object, quality: .standard),
            selectedFrameCount: 200
        )
        XCTAssertEqual(tune.tier, .high)
        XCTAssertEqual(tune.mapAnythingResolution, 518)
        XCTAssertEqual(tune.mapAnythingDirectViewLimit, 8)
        XCTAssertEqual(tune.mapAnythingAnchorMaxViews, 64)
        XCTAssertEqual(tune.mapAnythingWindowSize, 8)
        XCTAssertEqual(tune.mapAnythingWindowOverlap, 2)
        XCTAssertEqual(tune.vggtImageLoadResolution, 1280)
        XCTAssertEqual(tune.vggtFixedResolution, 518)
        XCTAssertEqual(tune.vggtMaxPoints, 150_000)
        XCTAssertEqual(tune.colmapMaxNumFeatures, 10_000)
        XCTAssertEqual(tune.colmapMaxNumMatches, 10_000)
        XCTAssertEqual(tune.sequentialOverlap, 12)
        XCTAssertEqual(tune.exhaustiveBlockSize, 25)
        XCTAssertEqual(tune.threadCap, 8)
        XCTAssertNil(tune.colmapMaxImageSizeCap)
        XCTAssertTrue(tune.vggtAllowed)
    }

    func testVggtAllowedThresholds() throws {
        let lowProfile = HardwareProfile(memoryGB: 8.0, cpuCount: 8, gpuWorkingSetGB: 8.0)
        let lowTune = AutoTuner.make(
            profile: lowProfile,
            preset: PresetSpec(mode: .object, quality: .standard),
            selectedFrameCount: 200
        )
        XCTAssertFalse(lowTune.vggtAllowed)

        let okProfile = HardwareProfile(memoryGB: 16.0, cpuCount: 8, gpuWorkingSetGB: nil)
        let okTune = AutoTuner.make(
            profile: okProfile,
            preset: PresetSpec(mode: .object, quality: .standard),
            selectedFrameCount: 200
        )
        XCTAssertTrue(okTune.vggtAllowed)
    }
}
