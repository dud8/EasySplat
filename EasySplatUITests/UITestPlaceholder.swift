import XCTest

#if !SWIFT_PACKAGE
import SwiftUI

final class EasySplatUITests: XCTestCase {
    func testLaunchAndHomeViewSmoke() throws {
        throw XCTSkip("Run UI tests from Xcode with a UI test host app.")
    }
}
#else
final class EasySplatUITests: XCTestCase {
    func testSkippedInSwiftPM() throws {
        throw XCTSkip("UI tests require Xcode UI test runner. Skipped in SwiftPM.")
    }
}
#endif
