import Metal
import XCTest
@testable import MetalSplatter

final class MetalBufferTests: XCTestCase {
    func testCapacityLimitRejectsGrowthWithoutMutatingStorage() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable")
        }

        let buffer = try MetalBuffer<UInt32>(
            device: device,
            capacity: 1,
            maximumCapacity: 1
        )
        buffer.append(42)

        XCTAssertThrowsError(try buffer.ensureCapacity(2))
        XCTAssertEqual(buffer.count, 1)
        XCTAssertEqual(buffer.values[0], 42)
    }
}
