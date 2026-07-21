import Darwin
import EasySplatCore
import Foundation
import XCTest
@testable import EasySplatBenchmarkDriverCore

final class OrientationEvidenceExtractorTests: XCTestCase {
    func testGaugeRotatedCandidateRemainsCorrectInsteadOfOldSourceWorldMisScore() throws {
        let gauge = TestQuaternion.axisAngle(x: 0, y: 0, z: 1, degrees: 90)
        let baseline = try makeFixture()
        defer { try? FileManager.default.removeItem(at: baseline.root) }
        let fixture = try makeFixture(candidateSourceToGroundTruth: gauge, canonical: gauge)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        // The removed source-world benchmark applied A directly to a ground-truth-world
        // label and would report 90 degrees for this harmless gauge choice.
        let physicalUp = TestVector(x: 0, y: 1, z: 0)
        XCTAssertEqual(gauge.rotated(physicalUp).angleDegrees(to: physicalUp), 90, accuracy: 1e-10)

        let baselineMetrics = try extract(baseline)
        let metrics = try extract(fixture)

        XCTAssertEqual(metrics.alignmentSupportCount, 10)
        assertQuaternion(metrics.candidateSourceToGroundTruthWXYZ, equals: gauge)
        XCTAssertEqual(metrics.alignmentMedianResidualDegrees, 0, accuracy: 1e-8)
        XCTAssertEqual(metrics.alignmentP90ResidualDegrees, 0, accuracy: 1e-8)
        XCTAssertEqual(try XCTUnwrap(metrics.orientationPhysicalUpErrorDegrees), 0, accuracy: 1e-8)
        XCTAssertEqual(
            try XCTUnwrap(metrics.orientationPhysicalUpErrorDegrees),
            try XCTUnwrap(baselineMetrics.orientationPhysicalUpErrorDegrees),
            accuracy: 1e-8
        )
        XCTAssertEqual(metrics.orientationSignCorrect, true)
    }

    func testWrongCanonicalRotationProducesARealPhysicalUpError() throws {
        let gauge = TestQuaternion.axisAngle(x: 0, y: 0, z: 1, degrees: 90)
        let fixture = try makeFixture(candidateSourceToGroundTruth: gauge, canonical: .identity)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let metrics = try extract(fixture)

        XCTAssertEqual(try XCTUnwrap(metrics.orientationPhysicalUpErrorDegrees), 90, accuracy: 1e-8)
        XCTAssertEqual(metrics.orientationSignCorrect, false)
    }

    func testVerifiedAndAxisUnverifiedAndUnresolvedHaveDistinctSemantics() throws {
        let upsideDown = TestQuaternion.axisAngle(x: 1, y: 0, z: 0, degrees: 180)
        let verified = try makeFixture(status: "verified", canonical: upsideDown)
        defer { try? FileManager.default.removeItem(at: verified.root) }
        let verifiedMetrics = try extract(verified)
        XCTAssertEqual(try XCTUnwrap(verifiedMetrics.orientationPhysicalUpErrorDegrees), 180, accuracy: 1e-8)
        XCTAssertEqual(verifiedMetrics.orientationSignCorrect, false)

        let axis = try makeFixture(status: "axisAlignedSignUnverified", canonical: upsideDown)
        defer { try? FileManager.default.removeItem(at: axis.root) }
        let axisMetrics = try extract(axis)
        XCTAssertEqual(try XCTUnwrap(axisMetrics.orientationPhysicalUpErrorDegrees), 0, accuracy: 1e-8)
        XCTAssertNil(axisMetrics.orientationSignCorrect)

        let unresolved = try makeFixture(status: "unresolved", canonical: nil)
        defer { try? FileManager.default.removeItem(at: unresolved.root) }
        let unresolvedMetrics = try extract(unresolved)
        XCTAssertNil(unresolvedMetrics.orientationPhysicalUpErrorDegrees)
        XCTAssertNil(unresolvedMetrics.orientationSignCorrect)
        XCTAssertEqual(unresolvedMetrics.alignmentSupportCount, 10)
    }

    func testOutputJSONIsClosedAndUsesSnakeCase() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let data = try JSONEncoder().encode(extract(fixture))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(object.keys), [
            "alignment_median_residual_degrees",
            "alignment_p90_residual_degrees",
            "alignment_support_count",
            "candidate_source_to_ground_truth_wxyz",
            "orientation_physical_up_error_degrees",
            "orientation_sign_correct",
            "orientation_status",
        ])
        XCTAssertEqual(object["orientation_status"] as? String, "verified")
        XCTAssertEqual((object["candidate_source_to_ground_truth_wxyz"] as? [Double])?.count, 4)
    }

    func testCandidateAuthoredTimingAndConfidenceCannotInfluenceEvidence() throws {
        let baseline = try makeFixture()
        defer { try? FileManager.default.removeItem(at: baseline.root) }
        let forged = try makeFixture(
            evidence: [
                "medianResidualDegrees": 179,
                "p90ResidualDegrees": 180,
                "bootstrapP95VariationDegrees": 180,
            ],
            timings: ["orientation_seconds": 99_999]
        )
        defer { try? FileManager.default.removeItem(at: forged.root) }

        XCTAssertEqual(try extract(forged), try extract(baseline))
    }

    func testCandidateImagesMustMatchGeometryManifestDigest() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try Data("# changed after the manifest was written\n".utf8)
            .append(to: fixture.candidateImages)

        XCTAssertThrowsError(try extract(fixture)) { error in
            XCTAssertTrue(error.localizedDescription.contains("images.txt digest"), error.localizedDescription)
        }
    }

    func testPreOpenGeometrySwapCannotSubstituteAuthenticatedExecutionBytes() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(
            try OrientationEvidenceExtractor.extract(
                geometryManifestURL: fixture.manifest,
                expectedGeometryManifestSHA256: "sha256:" + String(repeating: "0", count: 64),
                candidateImagesURL: fixture.candidateImages,
                expectedCandidateImagesSHA256: try MetalOffscreenRenderer.sha256(
                    fileAt: fixture.candidateImages
                ),
                groundTruthPosesURL: fixture.groundTruthPoses,
                expectedGroundTruthPosesSHA256: fixture.groundTruthSHA256,
                orientationLabelURL: fixture.label,
                expectedOrientationLabelSHA256: fixture.labelSHA256
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("geometry-manifest digest"),
                error.localizedDescription
            )
        }
    }

    func testPreOpenCandidateImagesSwapCannotSubstituteAuthenticatedGeometryBytes() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(
            try OrientationEvidenceExtractor.extract(
                geometryManifestURL: fixture.manifest,
                expectedGeometryManifestSHA256: try MetalOffscreenRenderer.sha256(
                    fileAt: fixture.manifest
                ),
                candidateImagesURL: fixture.candidateImages,
                expectedCandidateImagesSHA256: "sha256:" + String(repeating: "0", count: 64),
                groundTruthPosesURL: fixture.groundTruthPoses,
                expectedGroundTruthPosesSHA256: fixture.groundTruthSHA256,
                orientationLabelURL: fixture.label,
                expectedOrientationLabelSHA256: fixture.labelSHA256
            )
        ) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("candidate images digest"),
                error.localizedDescription
            )
        }
    }

    func testGroundTruthPoseDigestMustMatchPinnedReference() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(
            try OrientationEvidenceExtractor.extract(
                geometryManifestURL: fixture.manifest,
                expectedGeometryManifestSHA256: try MetalOffscreenRenderer.sha256(
                    fileAt: fixture.manifest
                ),
                candidateImagesURL: fixture.candidateImages,
                expectedCandidateImagesSHA256: try MetalOffscreenRenderer.sha256(
                    fileAt: fixture.candidateImages
                ),
                groundTruthPosesURL: fixture.groundTruthPoses,
                expectedGroundTruthPosesSHA256: "sha256:" + String(repeating: "0", count: 64),
                orientationLabelURL: fixture.label,
                expectedOrientationLabelSHA256: fixture.labelSHA256
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("ground-truth pose digest"), error.localizedDescription)
        }
    }

    func testPhysicalUpLabelIsPinnedAndUsesGroundTruthWorld() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        XCTAssertThrowsError(
            try OrientationEvidenceExtractor.extract(
                geometryManifestURL: fixture.manifest,
                expectedGeometryManifestSHA256: try MetalOffscreenRenderer.sha256(
                    fileAt: fixture.manifest
                ),
                candidateImagesURL: fixture.candidateImages,
                expectedCandidateImagesSHA256: try MetalOffscreenRenderer.sha256(
                    fileAt: fixture.candidateImages
                ),
                groundTruthPosesURL: fixture.groundTruthPoses,
                expectedGroundTruthPosesSHA256: fixture.groundTruthSHA256,
                orientationLabelURL: fixture.label,
                expectedOrientationLabelSHA256: "sha256:" + String(repeating: "0", count: 64)
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("orientation-label digest"), error.localizedDescription)
        }

        let oldGaugeLabel: [String: Any] = [
            "schema_version": 1,
            "coordinate_space": "source_world",
            "physical_up": ["x": 0.0, "y": 1.0, "z": 0.0],
        ]
        try JSONSerialization.data(withJSONObject: oldGaugeLabel, options: [.sortedKeys])
            .write(to: fixture.label)
        let digest = try MetalOffscreenRenderer.sha256(fileAt: fixture.label)
        XCTAssertThrowsError(
            try OrientationEvidenceExtractor.extract(
                geometryManifestURL: fixture.manifest,
                expectedGeometryManifestSHA256: try MetalOffscreenRenderer.sha256(
                    fileAt: fixture.manifest
                ),
                candidateImagesURL: fixture.candidateImages,
                expectedCandidateImagesSHA256: try MetalOffscreenRenderer.sha256(
                    fileAt: fixture.candidateImages
                ),
                groundTruthPosesURL: fixture.groundTruthPoses,
                expectedGroundTruthPosesSHA256: fixture.groundTruthSHA256,
                orientationLabelURL: fixture.label,
                expectedOrientationLabelSHA256: digest
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("ground-truth-world"), error.localizedDescription)
        }
    }

    func testGroundTruthPoseSchemaIsClosedAndRejectsDuplicateImageNames() throws {
        var fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.groundTruthPoses)) as? [String: Any]
        )
        object["unexpected"] = true
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: fixture.groundTruthPoses)
        fixture.groundTruthSHA256 = try MetalOffscreenRenderer.sha256(fileAt: fixture.groundTruthPoses)
        XCTAssertThrowsError(try extract(fixture)) { error in
            XCTAssertTrue(error.localizedDescription.contains("closed ground-truth pose schema"), error.localizedDescription)
        }

        fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.groundTruthPoses)) as? [String: Any]
        )
        var poses = try XCTUnwrap(object["poses"] as? [[String: Any]])
        poses.append(poses[0])
        object["poses"] = poses
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: fixture.groundTruthPoses)
        fixture.groundTruthSHA256 = try MetalOffscreenRenderer.sha256(fileAt: fixture.groundTruthPoses)
        XCTAssertThrowsError(try extract(fixture)) { error in
            XCTAssertTrue(error.localizedDescription.contains("duplicate image name"), error.localizedDescription)
        }
    }

    func testGroundTruthPoseContractRequiresWorldToCameraWXYZAndGroundTruthWorld() throws {
        var fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.groundTruthPoses)) as? [String: Any]
        )
        object["pose_convention"] = "camera_to_world"
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: fixture.groundTruthPoses)
        fixture.groundTruthSHA256 = try MetalOffscreenRenderer.sha256(fileAt: fixture.groundTruthPoses)

        XCTAssertThrowsError(try extract(fixture)) { error in
            XCTAssertTrue(error.localizedDescription.contains("world_to_camera"), error.localizedDescription)
        }
    }

    func testGroundTruthRotationsMustBeUnitLength() throws {
        var fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.groundTruthPoses)) as? [String: Any]
        )
        var poses = try XCTUnwrap(object["poses"] as? [[String: Any]])
        poses[0]["rcw_wxyz"] = ["w": 2.0, "x": 0.0, "y": 0.0, "z": 0.0]
        object["poses"] = poses
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: fixture.groundTruthPoses)
        fixture.groundTruthSHA256 = try MetalOffscreenRenderer.sha256(fileAt: fixture.groundTruthPoses)

        XCTAssertThrowsError(try extract(fixture)) { error in
            XCTAssertTrue(error.localizedDescription.contains("unit length"), error.localizedDescription)
        }
    }

    func testGeometryManifestRequiresProductionPoseConventions() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.manifest)) as? [String: Any]
        )
        manifest["poseConvention"] = "camera-to-world"
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: fixture.manifest)

        XCTAssertThrowsError(try extract(fixture)) { error in
            XCTAssertTrue(error.localizedDescription.contains("world-to-camera"), error.localizedDescription)
        }
    }

    func testAtLeastEightUniqueSharedPosesAreRequired() throws {
        let fixture = try makeFixture(count: 7)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(try extract(fixture)) { error in
            XCTAssertTrue(error.localizedDescription.contains("eight shared"), error.localizedDescription)
        }
    }

    func testRobustAverageIsDeterministicAndRejectsOneRotationOutlier() throws {
        let gauge = TestQuaternion.axisAngle(x: 0.2, y: 0.7, z: -0.3, degrees: 37)
        let outlier = TestQuaternion.axisAngle(x: 1, y: 0, z: 0, degrees: 100) * gauge
        let fixtureA = try makeFixture(
            count: 10,
            candidateSourceToGroundTruth: gauge,
            candidateOverrides: ["frame 0009.jpg": outlier],
            canonical: gauge
        )
        defer { try? FileManager.default.removeItem(at: fixtureA.root) }
        let fixtureB = try makeFixture(
            count: 10,
            candidateSourceToGroundTruth: gauge,
            candidateOverrides: ["frame 0009.jpg": outlier],
            canonical: gauge,
            reverseGroundTruthRecords: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureB.root) }

        let a = try extract(fixtureA)
        let b = try extract(fixtureB)
        XCTAssertEqual(a.candidateSourceToGroundTruthWXYZ, b.candidateSourceToGroundTruthWXYZ)
        XCTAssertLessThan(a.alignmentMedianResidualDegrees, 0.25)
        XCTAssertLessThan(a.alignmentP90ResidualDegrees, 0.25)
        assertQuaternion(a.candidateSourceToGroundTruthWXYZ, equals: gauge, tolerance: 0.1)
    }

    func testIncoherentPoseAlignmentIsRejected() throws {
        var overrides: [String: TestQuaternion] = [:]
        for index in 0..<10 {
            overrides[imageName(index)] = .axisAngle(x: 0, y: 1, z: 0, degrees: Double(index * 32))
        }
        let fixture = try makeFixture(candidateOverrides: overrides)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(try extract(fixture)) { error in
            XCTAssertTrue(error.localizedDescription.contains("alignment is not trustworthy"), error.localizedDescription)
        }
    }

    func testCandidateImagesParserPreservesSpacesAndRejectsMalformedAlternation() throws {
        let spaced = try makeFixture()
        defer { try? FileManager.default.removeItem(at: spaced.root) }
        XCTAssertNoThrow(try extract(spaced))

        var malformed = try makeFixture()
        defer { try? FileManager.default.removeItem(at: malformed.root) }
        try Data("99 1 0 0 0 0 0 0 1 missing-observations.jpg\n".utf8)
            .append(to: malformed.candidateImages)
        malformed = try rewriteManifestImagesDigest(malformed)
        XCTAssertThrowsError(try extract(malformed)) { error in
            XCTAssertTrue(error.localizedDescription.contains("observation line"), error.localizedDescription)
        }
    }

    func testCandidateImagesRequiresUniqueIDsAndFiniteNonzeroRotations() throws {
        var duplicate = try makeFixture()
        defer { try? FileManager.default.removeItem(at: duplicate.root) }
        try Data("1 1 0 0 0 0 0 0 1 another frame.jpg\n\n".utf8)
            .append(to: duplicate.candidateImages)
        duplicate = try rewriteManifestImagesDigest(duplicate)
        XCTAssertThrowsError(try extract(duplicate)) { error in
            XCTAssertTrue(error.localizedDescription.contains("duplicate image ID"), error.localizedDescription)
        }

        var zero = try makeFixture()
        defer { try? FileManager.default.removeItem(at: zero.root) }
        let text = try String(contentsOf: zero.candidateImages, encoding: .utf8)
            .replacingOccurrences(of: "1 1.0 0.0 0.0 0.0", with: "1 0 0 0 0")
        try Data(text.utf8).write(to: zero.candidateImages)
        zero = try rewriteManifestImagesDigest(zero)
        XCTAssertThrowsError(try extract(zero)) { error in
            XCTAssertTrue(error.localizedDescription.contains("nonzero"), error.localizedDescription)
        }
    }

    func testCandidateImagesRejectsSymlinksAndHardLinks() throws {
        let symlinkFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: symlinkFixture.root) }
        let real = symlinkFixture.root.appendingPathComponent("real-images.txt")
        try FileManager.default.moveItem(at: symlinkFixture.candidateImages, to: real)
        try FileManager.default.createSymbolicLink(at: symlinkFixture.candidateImages, withDestinationURL: real)
        XCTAssertThrowsError(try extract(symlinkFixture)) { error in
            XCTAssertTrue(error.localizedDescription.contains("ordinary file"), error.localizedDescription)
        }

        let hardlinkFixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: hardlinkFixture.root) }
        let hardlink = hardlinkFixture.root.appendingPathComponent("images-hardlink.txt")
        XCTAssertEqual(Darwin.link(hardlinkFixture.candidateImages.path, hardlink.path), 0)
        XCTAssertThrowsError(try extract(hardlinkFixture)) { error in
            XCTAssertTrue(error.localizedDescription.contains("ordinary file"), error.localizedDescription)
        }
    }

    func testResolvedOrientationRejectsNoncanonicalQuaternionSign() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.manifest)) as? [String: Any]
        )
        var orientation = try XCTUnwrap(manifest["canonicalOrientation"] as? [String: Any])
        orientation["sourceToCanonicalQuaternionWXYZ"] = ["w": -1.0, "x": 0.0, "y": 0.0, "z": 0.0]
        manifest["canonicalOrientation"] = orientation
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: fixture.manifest)

        XCTAssertThrowsError(try extract(fixture)) { error in
            XCTAssertTrue(error.localizedDescription.contains("sign"), error.localizedDescription)
        }
    }

    private func extract(_ fixture: Fixture) throws -> OrientationBenchmarkEvidence {
        try OrientationEvidenceExtractor.extract(
            geometryManifestURL: fixture.manifest,
            expectedGeometryManifestSHA256: try MetalOffscreenRenderer.sha256(
                fileAt: fixture.manifest
            ),
            candidateImagesURL: fixture.candidateImages,
            expectedCandidateImagesSHA256: try MetalOffscreenRenderer.sha256(
                fileAt: fixture.candidateImages
            ),
            groundTruthPosesURL: fixture.groundTruthPoses,
            expectedGroundTruthPosesSHA256: fixture.groundTruthSHA256,
            orientationLabelURL: fixture.label,
            expectedOrientationLabelSHA256: fixture.labelSHA256
        )
    }

    private func makeFixture(
        count: Int = 10,
        status: String = "verified",
        candidateSourceToGroundTruth gauge: TestQuaternion = .identity,
        candidateOverrides: [String: TestQuaternion] = [:],
        canonical: TestQuaternion? = .identity,
        evidence: [String: Double]? = nil,
        timings: [String: Double] = [:],
        reverseGroundTruthRecords: Bool = false
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let candidateImages = root.appendingPathComponent("images.txt")
        let manifest = root.appendingPathComponent("geometry_manifest.json")
        let label = root.appendingPathComponent("orientation-label.json")
        let groundTruth = root.appendingPathComponent("ground-truth-poses.json")

        var candidateText = "# Image list\n"
        var poses: [[String: Any]] = []
        for index in 0..<count {
            let name = imageName(index)
            let groundTruthRotation = TestQuaternion.axisAngle(
                x: 0,
                y: 1,
                z: 0,
                degrees: Double(index) * 7
            )
            let perImageGauge = candidateOverrides[name] ?? gauge
            let candidateRotation = groundTruthRotation * perImageGauge
            candidateText += "\(index + 1) \(candidateRotation.colmapText) 0 0 0 1 \(name)\n\n"
            poses.append([
                "image_name": name,
                "rcw_wxyz": groundTruthRotation.jsonObject,
            ])
        }
        try Data(candidateText.utf8).write(to: candidateImages)
        if reverseGroundTruthRecords { poses.reverse() }
        let groundTruthObject: [String: Any] = [
            "schema_version": 1,
            "pose_convention": "world_to_camera",
            "quaternion_order": "wxyz",
            "handedness": "right_handed",
            "coordinate_space": "ground_truth_world",
            "image_coordinates": "normalized_display_pixels",
            "poses": poses,
        ]
        try JSONSerialization.data(withJSONObject: groundTruthObject, options: [.sortedKeys])
            .write(to: groundTruth)

        var orientation: [String: Any] = ["status": status]
        if let canonical {
            orientation["sourceToCanonicalQuaternionWXYZ"] = canonical.jsonObject
        }
        if let evidence { orientation["evidence"] = evidence }
        let imagesDigest = try bareSHA256(fileAt: candidateImages)
        let manifestObject: [String: Any] = [
            "schemaVersion": GeometryArtifact.currentSchemaVersion,
            "poseConvention": "world-to-camera",
            "quaternionOrder": "wxyz",
            "handedness": "right-handed",
            "modelHashes": [
                "cameras.txt": String(repeating: "1", count: 64),
                "images.txt": imagesDigest,
                "points3D.txt": String(repeating: "2", count: 64),
            ],
            "canonicalOrientation": orientation,
            "timings": timings,
        ]
        try JSONSerialization.data(withJSONObject: manifestObject, options: [.sortedKeys])
            .write(to: manifest)
        let labelObject: [String: Any] = [
            "schema_version": 1,
            "coordinate_space": "ground_truth_world",
            "physical_up": ["x": 0.0, "y": 1.0, "z": 0.0],
        ]
        try JSONSerialization.data(withJSONObject: labelObject, options: [.sortedKeys])
            .write(to: label)

        return Fixture(
            root: root,
            manifest: manifest,
            candidateImages: candidateImages,
            groundTruthPoses: groundTruth,
            groundTruthSHA256: try MetalOffscreenRenderer.sha256(fileAt: groundTruth),
            label: label,
            labelSHA256: try MetalOffscreenRenderer.sha256(fileAt: label)
        )
    }

    private func rewriteManifestImagesDigest(_ fixture: Fixture) throws -> Fixture {
        var manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.manifest)) as? [String: Any]
        )
        var hashes = try XCTUnwrap(manifest["modelHashes"] as? [String: String])
        hashes["images.txt"] = try bareSHA256(fileAt: fixture.candidateImages)
        manifest["modelHashes"] = hashes
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: fixture.manifest)
        return fixture
    }

    private func bareSHA256(fileAt url: URL) throws -> String {
        let digest = try MetalOffscreenRenderer.sha256(fileAt: url)
        return digest.hasPrefix("sha256:") ? String(digest.dropFirst(7)) : digest
    }

    private func assertQuaternion(
        _ actual: [Double],
        equals expected: TestQuaternion,
        tolerance: Double = 1e-8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, 4, file: file, line: line)
        guard actual.count == 4 else { return }
        for (lhs, rhs) in zip(actual, expected.array) {
            XCTAssertEqual(lhs, rhs, accuracy: tolerance, file: file, line: line)
        }
    }
}

private struct Fixture {
    let root: URL
    let manifest: URL
    let candidateImages: URL
    let groundTruthPoses: URL
    var groundTruthSHA256: String
    let label: URL
    let labelSHA256: String
}

private func imageName(_ index: Int) -> String {
    String(format: "frame %04d.jpg", index)
}

private struct TestVector {
    let x: Double
    let y: Double
    let z: Double

    func angleDegrees(to other: TestVector) -> Double {
        let dot = min(1, max(-1, x * other.x + y * other.y + z * other.z))
        return acos(dot) * 180 / .pi
    }
}

private struct TestQuaternion {
    let w: Double
    let x: Double
    let y: Double
    let z: Double

    static let identity = TestQuaternion(w: 1, x: 0, y: 0, z: 0)

    static func axisAngle(x: Double, y: Double, z: Double, degrees: Double) -> TestQuaternion {
        let length = sqrt(x * x + y * y + z * z)
        let half = degrees * .pi / 360
        return TestQuaternion(
            w: cos(half),
            x: x / length * sin(half),
            y: y / length * sin(half),
            z: z / length * sin(half)
        ).canonicalized()
    }

    static func * (lhs: TestQuaternion, rhs: TestQuaternion) -> TestQuaternion {
        TestQuaternion(
            w: lhs.w * rhs.w - lhs.x * rhs.x - lhs.y * rhs.y - lhs.z * rhs.z,
            x: lhs.w * rhs.x + lhs.x * rhs.w + lhs.y * rhs.z - lhs.z * rhs.y,
            y: lhs.w * rhs.y - lhs.x * rhs.z + lhs.y * rhs.w + lhs.z * rhs.x,
            z: lhs.w * rhs.z + lhs.x * rhs.y - lhs.y * rhs.x + lhs.z * rhs.w
        ).canonicalized()
    }

    func rotated(_ vector: TestVector) -> TestVector {
        let tx = 2 * (y * vector.z - z * vector.y)
        let ty = 2 * (z * vector.x - x * vector.z)
        let tz = 2 * (x * vector.y - y * vector.x)
        return TestVector(
            x: vector.x + w * tx + y * tz - z * ty,
            y: vector.y + w * ty + z * tx - x * tz,
            z: vector.z + w * tz + x * ty - y * tx
        )
    }

    var array: [Double] { [w, x, y, z] }
    var jsonObject: [String: Double] { ["w": w, "x": x, "y": y, "z": z] }
    var colmapText: String { "\(w) \(x) \(y) \(z)" }

    private func canonicalized() -> TestQuaternion {
        let norm = sqrt(w * w + x * x + y * y + z * z)
        var result = TestQuaternion(w: w / norm, x: x / norm, y: y / norm, z: z / norm)
        if result.w < 0 || (result.w == 0 && [result.x, result.y, result.z].first(where: { $0 != 0 })! < 0) {
            result = TestQuaternion(w: -result.w, x: -result.x, y: -result.y, z: -result.z)
        }
        return result
    }
}

private extension Data {
    func append(to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
        try handle.synchronize()
    }
}
