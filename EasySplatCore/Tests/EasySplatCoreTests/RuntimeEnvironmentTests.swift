import XCTest
@testable import EasySplatCore

final class RuntimeEnvironmentTests: XCTestCase {
    func testCurrentReflectsSequentialMutations() async {
        let key = "EASYSPLAT_RUNTIME_ENVIRONMENT_TEST"

        await withEnvironmentAsync([key: "first"]) {
            XCTAssertEqual(RuntimeEnvironment.current[key], "first")
        }
        await withEnvironmentAsync([key: "second"]) {
            XCTAssertEqual(RuntimeEnvironment.current[key], "second")
        }
        await withEnvironmentAsync([key: nil]) {
            XCTAssertNil(RuntimeEnvironment.current[key])
        }
    }

    func testCurrentUsesReallocatedEnvironmentTable() async {
        let keys = (0..<128).map { "EASYSPLAT_RUNTIME_ENVIRONMENT_GROWTH_\($0)" }
        let changes = Dictionary(uniqueKeysWithValues: keys.enumerated().map { index, key in
            (key, String(repeating: "\(index)-", count: 64) as String?)
        })

        await withEnvironmentAsync(changes) {
            let snapshot = RuntimeEnvironment.current
            for (index, key) in keys.enumerated() {
                XCTAssertEqual(snapshot[key], String(repeating: "\(index)-", count: 64))
            }
        }
    }
}
