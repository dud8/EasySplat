#if canImport(XCTest) && os(macOS)
import Darwin
import XCTest
@testable import EasySplatCore

final class GeometryMemorySamplerTests: XCTestCase {
    func testMeasuresCurrentGeometryRunWithoutInheritingPriorPeak() throws {
        let allocationSize = 64 * 1_024 * 1_024
        let allocation = mmap(
            nil,
            allocationSize,
            PROT_READ | PROT_WRITE,
            MAP_ANON | MAP_PRIVATE,
            -1,
            0
        )
        guard allocation != MAP_FAILED else {
            throw POSIXError(.ENOMEM)
        }
        var allocationIsMapped = true
        defer {
            if allocationIsMapped {
                _ = munmap(allocation, allocationSize)
            }
        }

        let highRun = GeometryMemorySampler(sampleInterval: 0.01)
        highRun.start()
        memset(allocation, 0x5a, allocationSize)
        usleep(40_000)
        let highPeak = try XCTUnwrap(highRun.stop())
        XCTAssertGreaterThan(highPeak, 0)
        XCTAssertEqual(munmap(allocation, allocationSize), 0)
        allocationIsMapped = false

        usleep(40_000)
        let lowRun = GeometryMemorySampler(sampleInterval: 0.01)
        lowRun.start()
        usleep(40_000)
        let lowPeak = try XCTUnwrap(lowRun.stop())

        XCTAssertGreaterThan(lowPeak, 0)
        XCTAssertGreaterThan(highPeak - lowPeak, Int64(allocationSize / 2))
    }
}
#endif
