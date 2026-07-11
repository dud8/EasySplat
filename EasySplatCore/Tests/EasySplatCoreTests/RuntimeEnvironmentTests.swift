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
}
