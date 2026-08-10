import Foundation
import XCTest
@testable import EasySplatCore

final class DatasetPairPlannerTests: XCTestCase {
    private func identityPoseCamera(name: String, tx: Double, ty: Double = 0, tz: Double = 0) -> DatasetPairPlanner.Camera {
        // Identity rotation: camera center is simply -t.
        DatasetPairPlanner.Camera(
            name: name,
            pose: DatasetPoseConvention.ColmapPose(qw: 1, qx: 0, qy: 0, qz: 0, tx: tx, ty: ty, tz: tz)
        )
    }

    func testSmallSetsMatchExhaustively() {
        let cameras = (0..<5).map { identityPoseCamera(name: "f\($0).jpg", tx: Double($0)) }
        let pairs = DatasetPairPlanner.pairs(for: cameras)
        XCTAssertEqual(pairs.count, 10)
        XCTAssertTrue(pairs.allSatisfy { $0.0 < $0.1 })
    }

    func testLargeSetsPreferSpatialNeighbors() {
        // 100 cameras along a line, spaced 1 apart; each camera's nearest
        // neighbors are its adjacent indices.
        let cameras = (0..<100).map { identityPoseCamera(name: String(format: "f%03d.jpg", $0), tx: Double($0)) }
        let pairs = DatasetPairPlanner.pairs(for: cameras, neighborCount: 4)
        let pairSet = Set(pairs.map { "\($0.0)|\($0.1)" })

        // Adjacent cameras must be paired.
        XCTAssertTrue(pairSet.contains("f050.jpg|f051.jpg"))
        // Distant ends must not be.
        XCTAssertFalse(pairSet.contains("f000.jpg|f099.jpg"))
        // Bounded output: at most images * neighborCount pairs.
        XCTAssertLessThanOrEqual(pairs.count, 100 * 4)
        // Every camera appears in at least one pair.
        var names = Set<String>()
        for pair in pairs {
            names.insert(pair.0)
            names.insert(pair.1)
        }
        XCTAssertEqual(names.count, 100)
    }

    func testDeterministicAcrossInputOrder() {
        let cameras = (0..<80).map {
            identityPoseCamera(name: "f\($0).jpg", tx: Double($0 % 9), ty: Double($0 / 9))
        }
        let forward = DatasetPairPlanner.pairs(for: cameras)
        let reversedInput = DatasetPairPlanner.pairs(for: cameras.reversed())
        XCTAssertEqual(forward.map { "\($0.0)|\($0.1)" }, reversedInput.map { "\($0.0)|\($0.1)" })
    }

    func testCameraCenterAndViewDirection() {
        // 180-degree rotation about X (the identity-import pose): forward
        // becomes -Z in world; center is -R^T t.
        let pose = DatasetPoseConvention.ColmapPose(qw: 0, qx: 1, qy: 0, qz: 0, tx: 0, ty: 1, tz: 2)
        let center = DatasetPairPlanner.cameraCenter(of: pose)
        XCTAssertEqual(center.x, 0, accuracy: 1e-12)
        XCTAssertEqual(center.y, 1, accuracy: 1e-12)
        XCTAssertEqual(center.z, 2, accuracy: 1e-12)
        let forward = DatasetPairPlanner.viewDirection(of: pose)
        XCTAssertEqual(forward.x, 0, accuracy: 1e-12)
        XCTAssertEqual(forward.y, 0, accuracy: 1e-12)
        XCTAssertEqual(forward.z, -1, accuracy: 1e-12)
    }

    func testMatchListFormat() {
        XCTAssertEqual(
            DatasetPairPlanner.matchListText([("a.jpg", "b.jpg"), ("a.jpg", "c.jpg")]),
            "a.jpg b.jpg\na.jpg c.jpg\n"
        )
        XCTAssertEqual(DatasetPairPlanner.matchListText([]), "")
    }
}
