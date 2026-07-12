import XCTest
@testable import EasySplatCore

final class ReleaseIdentityTests: XCTestCase {
    func testReleaseVersionPrefersFullPrereleaseIdentity() {
        XCTAssertEqual(
            EasySplatReleaseIdentity.version(in: [
                "CFBundleShortVersionString": "0.2.0",
                "EasySplatReleaseVersion": "0.2.0-beta.1",
            ]),
            "0.2.0-beta.1"
        )
    }

    func testReleaseVersionFallsBackToNumericBundleVersion() {
        XCTAssertEqual(
            EasySplatReleaseIdentity.version(in: [
                "CFBundleShortVersionString": "0.2.0",
            ]),
            "0.2.0"
        )
        XCTAssertEqual(EasySplatReleaseIdentity.version(in: [:]), "0.0.0")
    }
}
