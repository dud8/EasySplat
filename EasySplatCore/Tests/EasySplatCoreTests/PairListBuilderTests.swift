#if canImport(XCTest)
import XCTest
@testable import EasySplatCore

final class PairListBuilderTests: XCTestCase {
    func testBuildPairsSequentialWithinGroups() {
        let groups = [
            FrameGroup(id: "video_000", fileNames: ["a.jpg", "b.jpg", "c.jpg", "d.jpg"], isVideo: true),
            FrameGroup(id: "video_001", fileNames: ["e.jpg", "f.jpg"], isVideo: true)
        ]

        let pairs = PairListBuilder.buildPairs(groups: groups, overlap: 2, stride: 1, bridgeCount: 0)
        let keys = pairKeys(pairs)

        let expected: Set<String> = [
            key("a.jpg", "b.jpg"),
            key("a.jpg", "c.jpg"),
            key("b.jpg", "c.jpg"),
            key("b.jpg", "d.jpg"),
            key("c.jpg", "d.jpg"),
            key("e.jpg", "f.jpg")
        ]
        XCTAssertEqual(keys, expected)
    }

    func testBuildPairsAddsBridgesBetweenVideos() {
        let groups = [
            FrameGroup(id: "video_000", fileNames: ["a.jpg", "b.jpg"], isVideo: true),
            FrameGroup(id: "video_001", fileNames: ["c.jpg", "d.jpg"], isVideo: true)
        ]

        let pairs = PairListBuilder.buildPairs(groups: groups, overlap: 1, stride: 1, bridgeCount: 1)
        let keys = pairKeys(pairs)

        XCTAssertTrue(keys.contains(key("b.jpg", "c.jpg")))
    }

    func testBuildPairsSkipsBridgeForPhotos() {
        let groups = [
            FrameGroup(id: "video_000", fileNames: ["a.jpg", "b.jpg"], isVideo: true),
            FrameGroup(id: "photos", fileNames: ["c.jpg", "d.jpg"], isVideo: false)
        ]

        let pairs = PairListBuilder.buildPairs(groups: groups, overlap: 1, stride: 1, bridgeCount: 1)
        let keys = pairKeys(pairs)

        XCTAssertFalse(keys.contains(key("b.jpg", "c.jpg")))
    }

    private func pairKeys(_ pairs: [(String, String)]) -> Set<String> {
        Set(pairs.map { key($0.0, $0.1) })
    }

    private func key(_ a: String, _ b: String) -> String {
        a < b ? "\(a)|\(b)" : "\(b)|\(a)"
    }
}
#endif
