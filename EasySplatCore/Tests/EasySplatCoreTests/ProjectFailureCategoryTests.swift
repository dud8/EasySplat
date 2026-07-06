import XCTest
@testable import EasySplatCore

final class ProjectFailureCategoryTests: XCTestCase {
    func testEmptyMessageReturnsUnknown() {
        XCTAssertEqual(ProjectFailureCategory.classify(message: nil), .unknown)
        XCTAssertEqual(ProjectFailureCategory.classify(message: ""), .unknown)
        XCTAssertEqual(ProjectFailureCategory.classify(message: "   "), .unknown)
    }

    func testClassifiesLowQualityReconstructionMessage() {
        XCTAssertEqual(
            ProjectFailureCategory.classify(message: "I couldn't get a stable camera solve. Try a slower capture and more light."),
            .lowQualityReconstruction
        )
        XCTAssertEqual(
            ProjectFailureCategory.classify(message: "Low-quality reconstruction. registered 4/30 (13%)"),
            .lowQualityReconstruction
        )
    }

    func testClassifiesInsufficientInputs() {
        XCTAssertEqual(
            ProjectFailureCategory.classify(message: "expected at least 12 frames"),
            .insufficientInputImages
        )
    }

    func testClassifiesLiveInsufficientInputMessage() {
        // Verbatim user message from PipelineRunner+Recovery so the hint
        // actually fires for the real failure path.
        XCTAssertEqual(
            ProjectFailureCategory.classify(message: "At least two usable photos or video frames are required."),
            .insufficientInputImages
        )
    }

    func testClassifiesNoUsablePhotosMessage() {
        XCTAssertEqual(
            ProjectFailureCategory.classify(message: "No usable photos or video frames were found."),
            .insufficientInputImages
        )
    }

    func testClassifiesToolchainErrors() {
        XCTAssertEqual(
            ProjectFailureCategory.classify(message: "Failed to download toolchain manifest"),
            .toolchainUnavailable
        )
    }

    func testClassifiesDiskSpace() {
        XCTAssertEqual(
            ProjectFailureCategory.classify(message: "No space left on device"),
            .diskSpace
        )
    }

    func testDiskSpaceWinsOverToolchainWhenMessageMentionsBoth() {
        // A toolchain download failing because the disk is full must surface
        // the disk-space hint, not the network/manifest hint.
        XCTAssertEqual(
            ProjectFailureCategory.classify(
                message: "Failed to download toolchain manifest: no space left on device"
            ),
            .diskSpace
        )
    }

    func testPermissionWinsOverToolchainWhenMessageMentionsBoth() {
        XCTAssertEqual(
            ProjectFailureCategory.classify(
                message: "Failed to write toolchain to disk: Operation not permitted"
            ),
            .sandboxOrPermission
        )
    }

    func testClassifiesSandboxAndPermission() {
        XCTAssertEqual(
            ProjectFailureCategory.classify(message: "Permission denied: /Users/example/Photos"),
            .sandboxOrPermission
        )
    }

    func testFallsThroughToUnknownForGenericErrors() {
        XCTAssertEqual(
            ProjectFailureCategory.classify(message: "Something unrecognized happened"),
            .unknown
        )
    }

    func testEveryCategoryShipsAHint() {
        for category in [ProjectFailureCategory.lowQualityReconstruction,
                         .insufficientInputImages,
                         .toolchainUnavailable,
                         .diskSpace,
                         .sandboxOrPermission,
                         .canceledByUser,
                         .unknown] {
            XCTAssertNotNil(category.hint, "Category \(category.rawValue) should ship a hint")
        }
        // Unknown's hint should at minimum mention Copy Diagnostics so the
        // user has a concrete next step rather than a dead-end error.
        XCTAssertTrue(
            ProjectFailureCategory.unknown.hint?.contains("Diagnostics") ?? false,
            "Unknown failures should at least direct the user to the diagnostic bundle"
        )
    }
}
