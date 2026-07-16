import Foundation
import XCTest
@testable import EasySplatCore

final class CanonicalColmapModelTransformerTests: XCTestCase {
    func testResolvedOrientationAtomicallyCanonicalizesPosesPointsAndLearnedInitializer() throws {
        let fixture = try makeFixture()
        let sourceCameras = try Data(contentsOf: fixture.model.appendingPathComponent("cameras.txt"))
        let sourceObservations = observationLines(
            try String(contentsOf: fixture.model.appendingPathComponent("images.txt"), encoding: .utf8)
        )
        let sourceInitializer = try Data(contentsOf: fixture.learnedInitializer)
        let sourcePointTokens = try dataTokens(
            at: fixture.model.appendingPathComponent("points3D.txt"),
            line: 1
        )
        let sourceMeasurement = try ColmapResidualAnalyzer.analyze(modelDirectory: fixture.model)
        let sourceSnapshot = try GeometryModelSnapshot.capture(in: fixture.model)

        let result = try CanonicalColmapModelTransformer.canonicalize(
            modelDirectory: fixture.model,
            solution: resolvedSolution(status: .verified),
            sourceMeasurement: sourceMeasurement,
            sourceSnapshot: sourceSnapshot,
            learnedPointInitializer: .init(
                sourceURL: fixture.learnedInitializer,
                expectedPointCount: 1,
                expectedSHA256: GeometryArtifactStore.sha256(of: fixture.learnedInitializer)
            )
        )

        XCTAssertTrue(result.didTransform)
        XCTAssertEqual(result.artifact.status, .verified)
        XCTAssertEqual(result.maximumResidualDifference, 0, accuracy: 1e-12)
        XCTAssertEqual(
            try Data(contentsOf: fixture.model.appendingPathComponent("cameras.txt")),
            sourceCameras
        )
        XCTAssertEqual(
            observationLines(
                try String(contentsOf: fixture.model.appendingPathComponent("images.txt"), encoding: .utf8)
            ),
            sourceObservations
        )
        XCTAssertEqual(try Data(contentsOf: fixture.learnedInitializer), sourceInitializer)

        let points = try dataTokens(
            at: fixture.model.appendingPathComponent("points3D.txt"),
            line: 1
        )
        XCTAssertEqual(Double(points[1])!, 0, accuracy: 1e-12)
        XCTAssertEqual(Double(points[2])!, 1, accuracy: 1e-12)
        XCTAssertEqual(Double(points[3])!, 10, accuracy: 1e-12)
        XCTAssertEqual(points[0], sourcePointTokens[0])
        XCTAssertEqual(Array(points[4...]), Array(sourcePointTokens[4...]))

        let canonicalInitializer = fixture.model.appendingPathComponent(
            CanonicalColmapModelTransformer.canonicalLearnedPointFileName
        )
        let initializer = try dataTokens(at: canonicalInitializer, line: 1)
        XCTAssertEqual(Double(initializer[1])!, 0, accuracy: 1e-12)
        XCTAssertEqual(Double(initializer[2])!, 2, accuracy: 1e-12)
        XCTAssertEqual(Double(initializer[3])!, 10, accuracy: 1e-12)
        XCTAssertEqual(result.learnedPointInitializer?.pointCount, 1)
        XCTAssertEqual(
            result.learnedPointInitializer?.sha256,
            try GeometryArtifactStore.sha256(of: canonicalInitializer)
        )

        let pose = try dataTokens(
            at: fixture.model.appendingPathComponent("images.txt"),
            line: 1
        )
        let poseMatrix = try XCTUnwrap(
            orientationMatrix(
                qw: Double(pose[1])!,
                qx: Double(pose[2])!,
                qy: Double(pose[3])!,
                qz: Double(pose[4])!
            )
        )
        let expected = resolvedSolution(status: .verified).sourceToCanonical.transposed
        assertMatrix(poseMatrix, equals: expected)
        XCTAssertEqual(Array(pose[5...8]), ["0", "0", "0", "1"])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.model.appendingPathComponent(
                    CanonicalColmapModelTransformer.receiptFileName
                ).path
            )
        )
        try GeometryModelSnapshot.validate(result.snapshot, at: fixture.model)
    }

    func testAxisAlignedSignUnverifiedBakesDeterministicProperAxisRotation() throws {
        let fixture = try makeFixture()
        let sourceMeasurement = try ColmapResidualAnalyzer.analyze(modelDirectory: fixture.model)
        let sourceSnapshot = try GeometryModelSnapshot.capture(in: fixture.model)

        let result = try CanonicalColmapModelTransformer.canonicalize(
            modelDirectory: fixture.model,
            solution: resolvedSolution(status: .axisAlignedSignUnverified),
            sourceMeasurement: sourceMeasurement,
            sourceSnapshot: sourceSnapshot,
            learnedPointInitializer: nil
        )

        XCTAssertEqual(result.artifact.status, .axisAlignedSignUnverified)
        XCTAssertEqual(result.maximumResidualDifference, 0, accuracy: 1e-12)
        XCTAssertEqual(
            try XCTUnwrap(result.artifact.sourceToCanonicalQuaternionWXYZ).z,
            1 / sqrt(2),
            accuracy: 1e-12
        )
        XCTAssertEqual(
            resolvedSolution(status: .axisAlignedSignUnverified).sourceToCanonical.determinant,
            1,
            accuracy: 1e-12
        )
    }

    func testUnresolvedOrientationLeavesAcceptedModelByteIdentical() throws {
        let fixture = try makeFixture()
        let before = try requiredModelData(in: fixture.model)
        let sourceMeasurement = try ColmapResidualAnalyzer.analyze(modelDirectory: fixture.model)
        let sourceSnapshot = try GeometryModelSnapshot.capture(in: fixture.model)
        let solution = CanonicalOrientationSolution(
            artifact: .unresolved(
                openingViewDirection: CanonicalDirection(x: 0, y: 0, z: 1)
            ),
            sourceToCanonical: .identity
        )

        let result = try CanonicalColmapModelTransformer.canonicalize(
            modelDirectory: fixture.model,
            solution: solution,
            sourceMeasurement: sourceMeasurement,
            sourceSnapshot: sourceSnapshot,
            learnedPointInitializer: nil
        )

        XCTAssertFalse(result.didTransform)
        XCTAssertEqual(result.maximumResidualDifference, 0)
        XCTAssertEqual(try requiredModelData(in: fixture.model), before)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.model.appendingPathComponent(
                    CanonicalColmapModelTransformer.receiptFileName
                ).path
            )
        )
    }

    func testPublishedReceiptPreventsASecondRotationAfterMetadataFailure() throws {
        let fixture = try makeFixture()
        let sourceMeasurement = try ColmapResidualAnalyzer.analyze(modelDirectory: fixture.model)
        let first = try CanonicalColmapModelTransformer.canonicalize(
            modelDirectory: fixture.model,
            solution: resolvedSolution(status: .verified),
            sourceMeasurement: sourceMeasurement,
            sourceSnapshot: GeometryModelSnapshot.capture(in: fixture.model),
            learnedPointInitializer: nil
        )
        let once = try requiredModelData(in: fixture.model)
        let canonicalMeasurement = try ColmapResidualAnalyzer.analyze(modelDirectory: fixture.model)

        let restored = try XCTUnwrap(
            CanonicalColmapModelTransformer.loadPublishedResult(
                modelDirectory: fixture.model,
                measurement: canonicalMeasurement
            )
        )

        XCTAssertFalse(restored.didTransform)
        XCTAssertEqual(restored.artifact, first.artifact)
        XCTAssertEqual(try requiredModelData(in: fixture.model), once)
        try GeometryModelSnapshot.validate(restored.snapshot, at: fixture.model)
    }

    func testInvalidLearnedInitializerFailsBeforeReplacingAcceptedModel() throws {
        let fixture = try makeFixture()
        let before = try requiredModelData(in: fixture.model)
        let sourceMeasurement = try ColmapResidualAnalyzer.analyze(modelDirectory: fixture.model)

        XCTAssertThrowsError(
            try CanonicalColmapModelTransformer.canonicalize(
                modelDirectory: fixture.model,
                solution: resolvedSolution(status: .verified),
                sourceMeasurement: sourceMeasurement,
                sourceSnapshot: GeometryModelSnapshot.capture(in: fixture.model),
                learnedPointInitializer: .init(
                    sourceURL: fixture.learnedInitializer,
                    expectedPointCount: 1,
                    expectedSHA256: String(repeating: "0", count: 64)
                )
            )
        )

        XCTAssertEqual(try requiredModelData(in: fixture.model), before)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.model.deletingLastPathComponent().path
            ).contains { $0.hasPrefix(".canonical-model-") }
        )
    }

    func testFailureAfterSwapDurablyRestoresAcceptedModel() throws {
        let fixture = try makeFixture()
        let before = try requiredModelData(in: fixture.model)
        let sourceMeasurement = try ColmapResidualAnalyzer.analyze(modelDirectory: fixture.model)

        XCTAssertThrowsError(
            try CanonicalColmapModelTransformer.canonicalize(
                modelDirectory: fixture.model,
                solution: resolvedSolution(status: .verified),
                sourceMeasurement: sourceMeasurement,
                sourceSnapshot: GeometryModelSnapshot.capture(in: fixture.model),
                learnedPointInitializer: nil,
                publicationCheckpoint: { checkpoint in
                    if checkpoint == .afterSwap { throw InjectedFailure.afterSwap }
                }
            )
        ) { error in
            XCTAssertEqual(error as? InjectedFailure, .afterSwap)
        }

        XCTAssertEqual(try requiredModelData(in: fixture.model), before)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.model.appendingPathComponent(
                    CanonicalColmapModelTransformer.receiptFileName
                ).path
            )
        )
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.model.deletingLastPathComponent().path
            ).contains { $0.hasPrefix(".canonical-model-") }
        )
    }

    private struct Fixture {
        let root: URL
        let model: URL
        let learnedInitializer: URL
    }

    private enum InjectedFailure: Error, Equatable {
        case afterSwap
    }

    private func makeFixture() throws -> Fixture {
        let root = try TestFileBuilder.makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("0", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: false)
        try "1 SIMPLE_PINHOLE 640 480 100 320 240\n".write(
            to: model.appendingPathComponent("cameras.txt"),
            atomically: true,
            encoding: .utf8
        )
        let imageRecords = (1...8).map { imageID in
            "\(imageID) 1 0 0 0 0 0 0 1 folder/frame  \(imageID).jpg\n330 240 1"
        }.joined(separator: "\n") + "\n"
        try imageRecords.write(
            to: model.appendingPathComponent("images.txt"),
            atomically: true,
            encoding: .utf8
        )
        let tracks = (1...8).map { "\($0) 0" }.joined(separator: " ")
        try "1 1 0 10 255 128 64 0 \(tracks)\n".write(
            to: model.appendingPathComponent("points3D.txt"),
            atomically: true,
            encoding: .utf8
        )
        let learnedInitializer = root.appendingPathComponent("learned_points3D.txt")
        try "1 2 0 10 1 2 3 -1.0\n".write(
            to: learnedInitializer,
            atomically: true,
            encoding: .utf8
        )
        return Fixture(root: root, model: model, learnedInitializer: learnedInitializer)
    }

    private func resolvedSolution(
        status: CanonicalOrientationStatus
    ) -> CanonicalOrientationSolution {
        let rotation = OrientationMatrix3(
            rows: OrientationVector3(x: 0, y: -1, z: 0),
            OrientationVector3(x: 1, y: 0, z: 0),
            OrientationVector3(x: 0, y: 0, z: 1)
        )
        let signAgreement = status == .verified ? 1.0 : 0.5
        return CanonicalOrientationSolution(
            artifact: CanonicalOrientationArtifact(
                status: status,
                method: .cameraRightNullspace,
                sourceToCanonicalQuaternionWXYZ: rotation.canonicalQuaternion(),
                evidence: CanonicalOrientationEvidence(
                    supportCount: 8,
                    eigenvalue0: 0.001,
                    eigenvalue1: 0.1,
                    eigenvalue2: 0.899,
                    eigengap: 100,
                    medianResidualDegrees: 0,
                    p90ResidualDegrees: 0,
                    medianAbsoluteImageUpAgreement: 1,
                    signAgreement: signAgreement,
                    bootstrapP95VariationDegrees: 0,
                    trajectoryPlaneAgreementDegrees: nil
                ),
                canonicalOpeningViewDirection: CanonicalDirection(x: 0, y: 0, z: 1)
            ),
            sourceToCanonical: rotation
        )
    }

    private func orientationMatrix(
        qw: Double,
        qx: Double,
        qy: Double,
        qz: Double
    ) -> OrientationMatrix3? {
        let norm = sqrt(qw * qw + qx * qx + qy * qy + qz * qz)
        guard norm.isFinite, norm > 0 else { return nil }
        let w = qw / norm
        let x = qx / norm
        let y = qy / norm
        let z = qz / norm
        return OrientationMatrix3(
            rows: OrientationVector3(
                x: 1 - 2 * (y * y + z * z),
                y: 2 * (x * y - z * w),
                z: 2 * (x * z + y * w)
            ),
            OrientationVector3(
                x: 2 * (x * y + z * w),
                y: 1 - 2 * (x * x + z * z),
                z: 2 * (y * z - x * w)
            ),
            OrientationVector3(
                x: 2 * (x * z - y * w),
                y: 2 * (y * z + x * w),
                z: 1 - 2 * (x * x + y * y)
            )
        )
    }

    private func requiredModelData(in model: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: ["cameras.txt", "images.txt", "points3D.txt"].map {
            ($0, try Data(contentsOf: model.appendingPathComponent($0)))
        })
    }

    private func dataTokens(at url: URL, line: Int) throws -> [String] {
        let records = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
        return records[line - 1].split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func observationLines(_ images: String) -> [String] {
        images.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap {
            $0.offset.isMultiple(of: 2) ? nil : String($0.element)
        }
    }

    private func assertMatrix(
        _ actual: OrientationMatrix3,
        equals expected: OrientationMatrix3,
        accuracy: Double = 1e-12,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for row in 0..<3 {
            for column in 0..<3 {
                XCTAssertEqual(
                    actual[row, column],
                    expected[row, column],
                    accuracy: accuracy,
                    file: file,
                    line: line
                )
            }
        }
    }
}
