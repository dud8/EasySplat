#if canImport(XCTest)
import Foundation
import SQLite3
import XCTest
@testable import EasySplatCore

final class ColmapFeatureEvidenceStoreTests: XCTestCase {
    func testStoreAcceptsCanonicalMissingPathThroughPrivateTemporaryAlias() throws {
        let root = URL(
            fileURLWithPath: "/private/tmp/EasySplat-FeatureEvidence-\(UUID().uuidString).easysplatproj",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let evidence = ColmapFeatureEvidence(
            selectedFramesDigest: String(repeating: "a", count: 64),
            imageNames: ["a.jpg", "b.jpg"],
            featureDatabaseDigest: String(repeating: "b", count: 64)
        )

        XCTAssertNoThrow(try ColmapFeatureEvidenceStore.save(
            evidence,
            to: paths.colmapFeatureEvidenceURL,
            projectPaths: paths
        ))
    }

    func testVerifiedEvidenceRejectsChangedFrameOrDescriptorBytes() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let names = ["a.jpg", "b.jpg"]
        let selectedDigest = try GeometryArtifactStore.selectedFramesDigest(
            orderedImageNames: names,
            projectPaths: fixture.paths
        )
        let featureDigest = try ColmapDatabaseDigester
            .digests(at: fixture.paths.colmapDatabaseURL).feature
        let evidence = ColmapFeatureEvidence(
            selectedFramesDigest: selectedDigest,
            imageNames: names,
            featureDatabaseDigest: featureDigest
        )
        try ColmapFeatureEvidenceStore.save(
            evidence,
            to: fixture.paths.colmapFeatureEvidenceURL,
            projectPaths: fixture.paths
        )

        XCTAssertEqual(
            try ColmapFeatureEvidenceStore.loadVerified(
                from: fixture.paths.colmapFeatureEvidenceURL,
                expectedImageNames: names,
                databaseURL: fixture.paths.colmapDatabaseURL,
                projectPaths: fixture.paths
            ),
            evidence
        )

        try Data("changed-a".utf8).write(
            to: fixture.paths.framesSelectedURL.appendingPathComponent("a.jpg"),
            options: [.atomic]
        )
        XCTAssertThrowsError(try ColmapFeatureEvidenceStore.loadVerified(
            from: fixture.paths.colmapFeatureEvidenceURL,
            expectedImageNames: names,
            databaseURL: fixture.paths.colmapDatabaseURL,
            projectPaths: fixture.paths
        ))

        try Data("a".utf8).write(
            to: fixture.paths.framesSelectedURL.appendingPathComponent("a.jpg"),
            options: [.atomic]
        )
        try execute(
            "UPDATE descriptors SET data = X'09' WHERE image_id = 1;",
            at: fixture.paths.colmapDatabaseURL
        )
        XCTAssertThrowsError(try ColmapFeatureEvidenceStore.loadVerified(
            from: fixture.paths.colmapFeatureEvidenceURL,
            expectedImageNames: names,
            databaseURL: fixture.paths.colmapDatabaseURL,
            projectPaths: fixture.paths
        ))
    }

    func testStoreRejectsNoncanonicalAndSymlinkedEvidencePaths() throws {
        let fixture = try makeProject()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let evidence = ColmapFeatureEvidence(
            selectedFramesDigest: String(repeating: "a", count: 64),
            imageNames: ["a.jpg", "b.jpg"],
            featureDatabaseDigest: String(repeating: "b", count: 64)
        )
        let outside = fixture.paths.root.appendingPathComponent("outside.json")

        XCTAssertThrowsError(try ColmapFeatureEvidenceStore.save(
            evidence,
            to: outside,
            projectPaths: fixture.paths
        ))

        try ColmapFeatureEvidenceStore.save(
            evidence,
            to: fixture.paths.colmapFeatureEvidenceURL,
            projectPaths: fixture.paths
        )
        let externalAlias = fixture.root.appendingPathComponent("feature-evidence-alias.json")
        try FileManager.default.createSymbolicLink(
            at: externalAlias,
            withDestinationURL: fixture.paths.colmapFeatureEvidenceURL
        )
        XCTAssertThrowsError(try ColmapFeatureEvidenceStore.save(
            evidence,
            to: externalAlias,
            projectPaths: fixture.paths
        ))
        XCTAssertNotNil(
            try? FileManager.default.destinationOfSymbolicLink(atPath: externalAlias.path)
        )

        try Data("{}".utf8).write(to: outside)
        try FileManager.default.removeItem(at: fixture.paths.colmapFeatureEvidenceURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.colmapFeatureEvidenceURL,
            withDestinationURL: outside
        )
        XCTAssertThrowsError(try ColmapFeatureEvidenceStore.load(
            from: fixture.paths.colmapFeatureEvidenceURL,
            projectPaths: fixture.paths
        ))
    }

    private func makeProject() throws -> (root: URL, paths: ProjectPaths) {
        let root = try TestFileBuilder.makeTempDir()
        let paths = ProjectPaths(
            root: root.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        )
        try paths.ensureDirectories()
        try Data("a".utf8).write(
            to: paths.framesSelectedURL.appendingPathComponent("a.jpg")
        )
        try Data("b".utf8).write(
            to: paths.framesSelectedURL.appendingPathComponent("b.jpg")
        )
        try execute(
            """
            CREATE TABLE cameras(camera_id INTEGER PRIMARY KEY);
            CREATE TABLE images(image_id INTEGER PRIMARY KEY, name TEXT, camera_id INTEGER);
            CREATE TABLE keypoints(image_id INTEGER PRIMARY KEY, rows INTEGER, cols INTEGER, data BLOB);
            CREATE TABLE descriptors(image_id INTEGER PRIMARY KEY, rows INTEGER, cols INTEGER, data BLOB);
            CREATE TABLE matches(pair_id INTEGER PRIMARY KEY, rows INTEGER, cols INTEGER, data BLOB);
            CREATE TABLE two_view_geometries(pair_id INTEGER PRIMARY KEY, rows INTEGER, cols INTEGER, data BLOB, config INTEGER);
            INSERT INTO cameras VALUES (1);
            INSERT INTO images VALUES (1, 'a.jpg', 1), (2, 'b.jpg', 1);
            INSERT INTO keypoints VALUES (1, 1, 4, X'01'), (2, 1, 4, X'02');
            INSERT INTO descriptors VALUES (1, 1, 128, X'01'), (2, 1, 128, X'02');
            """,
            at: paths.colmapDatabaseURL
        )
        return (root, paths)
    }

    private func execute(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "SQLite", code: 1)
        }
        defer { sqlite3_close(database) }
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        let detail = message.map { String(cString: $0) }
        sqlite3_free(message)
        guard result == SQLITE_OK else {
            throw NSError(
                domain: "SQLite",
                code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: detail ?? "SQLite failure"]
            )
        }
    }
}
#endif
