import Foundation
import XCTest
@testable import EasySplatCore

final class ExtractedFrameManifestTests: XCTestCase {
    func testRoundTripVerifiesEveryGroupAndFile() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let groups = try makeGroups(paths: paths, counts: [1, 2])

        let persisted = try ExtractedFrameManifestStore.persist(
            groups: groups,
            targetCounts: [1, 2],
            paths: paths
        )
        let loaded = try ExtractedFrameManifestStore.loadVerified(
            paths: paths,
            expectedVideoCount: 2,
            maximumTotalFrames: 3
        )

        XCTAssertEqual(loaded, persisted)
        XCTAssertEqual(
            try ExtractedFrameManifestStore.frameGroups(from: loaded, paths: paths)
                .map { $0.map(\.lastPathComponent) },
            groups.map { $0.map(\.lastPathComponent) }
        )
    }

    func testVerificationRejectsMissingManifestAndMutatedFile() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let groups = try makeGroups(paths: paths, counts: [1])

        XCTAssertThrowsError(try ExtractedFrameManifestStore.loadVerified(
            paths: paths,
            expectedVideoCount: 1,
            maximumTotalFrames: 10
        ))

        _ = try ExtractedFrameManifestStore.persist(
            groups: groups,
            targetCounts: [1],
            paths: paths
        )
        try Data("changed-0".utf8).write(to: groups[0][0])

        XCTAssertThrowsError(try ExtractedFrameManifestStore.loadVerified(
            paths: paths,
            expectedVideoCount: 1,
            maximumTotalFrames: 10
        ))
    }

    func testVerificationRejectsChangedOriginalReceiptEvidence() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let groups = try makeGroups(paths: paths, counts: [1])
        let source = ExtractedFrameSourceEvidence(
            projectRelativePath: "Originals/video-0000.mov",
            byteCount: 123,
            sha256: String(repeating: "a", count: 64)
        )
        _ = try ExtractedFrameManifestStore.persist(
            groups: groups.map { files in
                files.enumerated().map { index, file in
                    ExtractedFrameOutput(
                        url: file,
                        origin: VideoFrameOrigin(
                            decodedFrameIndex: index,
                            timestampSeconds: Double(index),
                            presentationTimeValue: nil,
                            presentationTimeTimescale: nil,
                            timestampWasRepaired: true
                        )
                    )
                }
            },
            targetCounts: [1],
            sourceEvidence: [source],
            paths: paths
        )

        XCTAssertNoThrow(try ExtractedFrameManifestStore.loadVerified(
            paths: paths,
            expectedSourceEvidence: [source],
            maximumTotalFrames: 1
        ))
        XCTAssertThrowsError(try ExtractedFrameManifestStore.loadVerified(
            paths: paths,
            expectedSourceEvidence: [ExtractedFrameSourceEvidence(
                projectRelativePath: source.projectRelativePath,
                byteCount: source.byteCount,
                sha256: String(repeating: "b", count: 64)
            )],
            maximumTotalFrames: 1
        ))
    }

    func testVerificationRejectsExtraEntries() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let groups = try makeGroups(paths: paths, counts: [1])
        _ = try ExtractedFrameManifestStore.persist(
            groups: groups,
            targetCounts: [1],
            paths: paths
        )

        TestFileBuilder.createFile(
            at: paths.framesRawURL
                .appendingPathComponent("video_000", isDirectory: true)
                .appendingPathComponent("unexpected.jpg"),
            data: Data("unexpected".utf8)
        )

        XCTAssertThrowsError(try ExtractedFrameManifestStore.loadVerified(
            paths: paths,
            expectedVideoCount: 1,
            maximumTotalFrames: 10
        ))
    }

    func testPersistRejectsUnexpectedRawEntryBeforePublishingManifest() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let groups = try makeGroups(paths: paths, counts: [1])
        TestFileBuilder.createFile(
            at: paths.framesRawURL
                .appendingPathComponent("video_000", isDirectory: true)
                .appendingPathComponent("unexpected.jpg"),
            data: Data("unexpected".utf8)
        )

        XCTAssertThrowsError(try ExtractedFrameManifestStore.persist(
            groups: groups,
            targetCounts: [1],
            paths: paths
        )) { error in
            XCTAssertEqual(error as? ExtractedFrameManifestError, .unsafeLayout)
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: paths.framesRawManifestURL.path)
        )
    }

    func testVerificationRejectsDuplicateAndTraversalNames() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let groups = try makeGroups(paths: paths, counts: [2])
        let valid = try ExtractedFrameManifestStore.persist(
            groups: groups,
            targetCounts: [2],
            paths: paths
        )
        let first = try XCTUnwrap(valid.groups.first?.files.first)

        for files in [
            [first, first],
            [first, ExtractedFrameFile(
                index: 1,
                fileName: "../escape.jpg",
                byteCount: first.byteCount,
                sha256: first.sha256
            )],
        ] {
            let invalid = ExtractedFrameManifest(
                schemaVersion: ExtractedFrameManifest.currentSchemaVersion,
                groups: [ExtractedFrameGroup(index: 0, targetCount: 2, files: files)]
            )
            try JSONEncoder().encode(invalid).write(
                to: paths.framesRawManifestURL,
                options: [.atomic]
            )
            XCTAssertThrowsError(try ExtractedFrameManifestStore.loadVerified(
                paths: paths,
                expectedVideoCount: 1,
                maximumTotalFrames: 2
            ))
        }
    }

    func testVerificationRejectsReorderedFrameRecords() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let groups = try makeGroups(paths: paths, counts: [3])
        let persisted = try ExtractedFrameManifestStore.persist(
            groups: groups,
            targetCounts: [3],
            paths: paths
        )
        let reordered = ExtractedFrameManifest(
            schemaVersion: persisted.schemaVersion,
            groups: [ExtractedFrameGroup(
                index: 0,
                targetCount: 3,
                files: Array(persisted.groups[0].files.reversed())
            )]
        )
        try JSONEncoder().encode(reordered).write(
            to: paths.framesRawManifestURL,
            options: [.atomic]
        )

        XCTAssertThrowsError(try ExtractedFrameManifestStore.loadVerified(
            paths: paths,
            expectedVideoCount: 1,
            maximumTotalFrames: 3
        ))
    }

    func testVerificationRejectsSymlinksAndHardLinks() throws {
        for linkKind in ["symbolic", "hard"] {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = ProjectPaths(root: root)
            try paths.ensureDirectories()
            let groups = try makeGroups(paths: paths, counts: [1])
            _ = try ExtractedFrameManifestStore.persist(
                groups: groups,
                targetCounts: [1],
                paths: paths
            )

            let original = groups[0][0]
            let replacement = root.appendingPathComponent("replacement.jpg")
            try FileManager.default.removeItem(at: original)
            if linkKind == "symbolic" {
                TestFileBuilder.createFile(at: replacement, data: Data("frame-0-0".utf8))
                try FileManager.default.createSymbolicLink(
                    at: original,
                    withDestinationURL: replacement
                )
            } else {
                TestFileBuilder.createFile(at: replacement, data: Data("frame-0-0".utf8))
                try FileManager.default.linkItem(at: replacement, to: original)
            }

            XCTAssertThrowsError(try ExtractedFrameManifestStore.loadVerified(
                paths: paths,
                expectedVideoCount: 1,
                maximumTotalFrames: 10
            ))
        }
    }

    func testVerificationRejectsSymlinkedRawAncestors() throws {
        for ancestor in ["raw", "group"] {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = ProjectPaths(root: root)
            try paths.ensureDirectories()
            let groups = try makeGroups(paths: paths, counts: [1])
            _ = try ExtractedFrameManifestStore.persist(
                groups: groups,
                targetCounts: [1],
                paths: paths
            )

            let source = ancestor == "raw"
                ? paths.framesRawURL
                : paths.framesRawURL.appendingPathComponent("video_000", isDirectory: true)
            let moved = root.appendingPathComponent("moved-\(ancestor)", isDirectory: true)
            try FileManager.default.moveItem(at: source, to: moved)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: moved)

            XCTAssertThrowsError(try ExtractedFrameManifestStore.loadVerified(
                paths: paths,
                expectedVideoCount: 1,
                maximumTotalFrames: 1
            ))
        }
    }

    func testVerificationRejectsHardLinkedManifest() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        let groups = try makeGroups(paths: paths, counts: [1])
        _ = try ExtractedFrameManifestStore.persist(
            groups: groups,
            targetCounts: [1],
            paths: paths
        )
        try FileManager.default.linkItem(
            at: paths.framesRawManifestURL,
            to: root.appendingPathComponent("manifest-copy.json")
        )

        XCTAssertThrowsError(try ExtractedFrameManifestStore.loadVerified(
            paths: paths,
            expectedVideoCount: 1,
            maximumTotalFrames: 1
        ))
    }

    private func makeGroups(paths: ProjectPaths, counts: [Int]) throws -> [[URL]] {
        try counts.enumerated().map { groupIndex, count in
            let directory = paths.framesRawURL.appendingPathComponent(
                String(format: "video_%03d", groupIndex),
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            return (0..<count).map { frameIndex in
                let file = directory.appendingPathComponent(
                    String(format: "frame_%06d.jpg", frameIndex)
                )
                TestFileBuilder.createFile(
                    at: file,
                    data: Data("frame-\(groupIndex)-\(frameIndex)".utf8)
                )
                return file
            }
        }
    }
}
