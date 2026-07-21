import Darwin
import Foundation
import XCTest
@testable import EasySplatCore

final class VideoFrameAnalysisArtifactStoreTests: XCTestCase {
    func testRoundTripBindsSourcePolicyClipAndCandidateEvidence() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root.appendingPathComponent("Project.easysplatproj"))
        try paths.ensureDirectories()

        let policy = VideoFrameAnalysisPolicy(targetFrameCeiling: 250, targetFPS: 3)
        let artifact = makeArtifact(policy: policy)
        let url = paths.videoFrameAnalysisURL(index: 0)
        let fileEvidence = try VideoFrameAnalysisArtifactStore.save(
            artifact,
            to: url,
            projectPaths: paths
        )
        let receipt = makeReceipt(
            artifact: artifact,
            fileEvidence: fileEvidence,
            analysisPath: try paths.projectRelativePath(for: url)
        )

        let loaded = try VideoFrameAnalysisArtifactStore.load(
            from: url,
            receipt: receipt,
            expectedPolicy: policy,
            expectedClipGroupID: "video_000",
            expectedSourceIndex: 0,
            projectPaths: paths
        )

        XCTAssertEqual(loaded, artifact)
        XCTAssertEqual(loaded.candidates.map(\.frameIndex), [0, 12, 29])
        XCTAssertEqual(loaded.candidates[1].presentationTimeValue, 12)
        XCTAssertEqual(loaded.candidates[1].presentationTimeTimescale, 30)
        XCTAssertEqual(loaded.candidates[2].dHash, 0x0f0f)
    }

    func testRegeneratedSaveUsesDigestBoundPathAndIsIdempotent() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root.appendingPathComponent("Project.easysplatproj"))
        try paths.ensureDirectories()
        let policy = VideoFrameAnalysisPolicy(targetFrameCeiling: 500, targetFPS: 4)
        let artifact = makeArtifact(policy: policy)

        let first = try VideoFrameAnalysisArtifactStore.saveRegenerated(
            artifact,
            projectPaths: paths
        )
        let second = try VideoFrameAnalysisArtifactStore.saveRegenerated(
            artifact,
            projectPaths: paths
        )

        XCTAssertEqual(first.url, second.url)
        XCTAssertEqual(first.evidence, second.evidence)
        XCTAssertEqual(
            first.url.lastPathComponent,
            "video-analysis-0000-\(first.evidence.sha256).json"
        )
        let receipt = makeReceipt(
            artifact: artifact,
            fileEvidence: first.evidence,
            analysisPath: try paths.projectRelativePath(for: first.url)
        )
        XCTAssertEqual(
            try VideoFrameAnalysisArtifactStore.load(
                from: first.url,
                receipt: receipt,
                expectedPolicy: policy,
                expectedClipGroupID: artifact.clipGroupID,
                expectedSourceIndex: 0,
                projectPaths: paths
            ),
            artifact
        )
        XCTAssertNotNil(first.cleanupToken)
        XCTAssertNil(second.cleanupToken)
    }

    func testCreationLedgerRollsBackCreatedArtifactAfterThrow() throws {
        enum Probe: Error { case stop }

        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root.appendingPathComponent("Project.easysplatproj"))
        try paths.ensureDirectories()
        let artifact = makeArtifact(
            policy: VideoFrameAnalysisPolicy(targetFrameCeiling: 500, targetFPS: 4)
        )
        var createdURL: URL?

        XCTAssertThrowsError(try {
            let ledger = VideoFrameAnalysisArtifactCreationLedger()
            defer { ledger.rollback() }
            let saved = try VideoFrameAnalysisArtifactStore.saveRegenerated(
                artifact,
                projectPaths: paths
            )
            createdURL = saved.url
            ledger.record(saved.cleanupToken)
            throw Probe.stop
        }()) { error in
            XCTAssertTrue(error is Probe)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(createdURL).path))
    }

    func testCreationLedgerPreservesPreexistingContentAddressedArtifact() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root.appendingPathComponent("Project.easysplatproj"))
        try paths.ensureDirectories()
        let artifact = makeArtifact(
            policy: VideoFrameAnalysisPolicy(targetFrameCeiling: 500, targetFPS: 4)
        )
        let preexisting = try VideoFrameAnalysisArtifactStore.saveRegenerated(
            artifact,
            projectPaths: paths
        )
        let reused = try VideoFrameAnalysisArtifactStore.saveRegenerated(
            artifact,
            projectPaths: paths
        )
        let ledger = VideoFrameAnalysisArtifactCreationLedger()
        ledger.record(reused.cleanupToken)

        ledger.rollback()

        XCTAssertNil(reused.cleanupToken)
        XCTAssertEqual(try Data(contentsOf: preexisting.url), try Data(contentsOf: reused.url))
    }

    func testExactRemovalRejectsDirectorySwappedIntoSidecarPath() throws {
        let fixture = try makeRemovalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let marker = fixture.url.appendingPathComponent("keep.txt")

        let removed = try VideoFrameAnalysisArtifactStore.removeExpectedRegularFile(
            fixture.token,
            beforeFinalIdentityCheck: {
                try FileManager.default.removeItem(at: fixture.url)
                try FileManager.default.createDirectory(at: fixture.url, withIntermediateDirectories: false)
                try Data("keep".utf8).write(to: marker)
            }
        )

        XCTAssertFalse(removed)
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
    }

    func testExactRemovalRejectsSymlinkSwappedIntoSidecarPath() throws {
        let fixture = try makeRemovalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = fixture.root.appendingPathComponent("target.json")
        try Data("keep".utf8).write(to: target)

        let removed = try VideoFrameAnalysisArtifactStore.removeExpectedRegularFile(
            fixture.token,
            beforeFinalIdentityCheck: {
                try FileManager.default.removeItem(at: fixture.url)
                try FileManager.default.createSymbolicLink(
                    at: fixture.url,
                    withDestinationURL: target
                )
            }
        )

        XCTAssertFalse(removed)
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
        var status = stat()
        XCTAssertEqual(lstat(fixture.url.path, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFLNK)
    }

    func testExactRemovalRejectsDifferentRegularFileSwappedIntoSidecarPath() throws {
        let fixture = try makeRemovalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let replacement = Data("replacement".utf8)

        let removed = try VideoFrameAnalysisArtifactStore.removeExpectedRegularFile(
            fixture.token,
            beforeFinalIdentityCheck: {
                try FileManager.default.removeItem(at: fixture.url)
                try replacement.write(to: fixture.url)
            }
        )

        XCTAssertFalse(removed)
        XCTAssertEqual(try Data(contentsOf: fixture.url), replacement)
    }

    func testExactRemovalRestoresFileSwappedAfterFinalIdentityCheck() throws {
        let fixture = try makeRemovalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let replacement = Data("late replacement".utf8)

        let removed = try VideoFrameAnalysisArtifactStore.removeExpectedRegularFile(
            fixture.token,
            beforeQuarantineRename: {
                try FileManager.default.removeItem(at: fixture.url)
                try replacement.write(to: fixture.url)
            }
        )

        XCTAssertFalse(removed)
        XCTAssertEqual(try Data(contentsOf: fixture.url), replacement)
    }

    func testExactRemovalRejectsSameInodeContentMutation() throws {
        let fixture = try makeRemovalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var before = stat()
        XCTAssertEqual(lstat(fixture.url.path, &before), 0)
        let replacement = Data("newly referenced artifact".utf8)

        let removed = try VideoFrameAnalysisArtifactStore.removeExpectedRegularFile(
            fixture.token,
            beforeFinalIdentityCheck: {
                let descriptor = Darwin.open(fixture.url.path, O_WRONLY | O_TRUNC | O_NOFOLLOW)
                XCTAssertGreaterThanOrEqual(descriptor, 0)
                defer { Darwin.close(descriptor) }
                replacement.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    XCTAssertEqual(Darwin.write(descriptor, base, bytes.count), bytes.count)
                }
            }
        )

        var after = stat()
        XCTAssertEqual(lstat(fixture.url.path, &after), 0)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertFalse(removed)
        XCTAssertEqual(try Data(contentsOf: fixture.url), replacement)
    }

    func testExactRemovalRestoresSameInodeMutationAfterFinalDigestCheck() throws {
        let fixture = try makeRemovalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var before = stat()
        XCTAssertEqual(lstat(fixture.url.path, &before), 0)
        let replacement = Data("late newly referenced artifact".utf8)

        let removed = try VideoFrameAnalysisArtifactStore.removeExpectedRegularFile(
            fixture.token,
            beforeQuarantineRename: {
                let descriptor = Darwin.open(fixture.url.path, O_WRONLY | O_TRUNC | O_NOFOLLOW)
                XCTAssertGreaterThanOrEqual(descriptor, 0)
                defer { Darwin.close(descriptor) }
                replacement.withUnsafeBytes { bytes in
                    guard let base = bytes.baseAddress else { return }
                    XCTAssertEqual(Darwin.write(descriptor, base, bytes.count), bytes.count)
                }
            }
        )

        var after = stat()
        XCTAssertEqual(lstat(fixture.url.path, &after), 0)
        XCTAssertEqual(after.st_ino, before.st_ino)
        XCTAssertFalse(removed)
        XCTAssertEqual(try Data(contentsOf: fixture.url), replacement)
    }

    func testExactRemovalUnlinksExpectedRegularSidecar() throws {
        let fixture = try makeRemovalFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertTrue(
            try VideoFrameAnalysisArtifactStore.removeExpectedRegularFile(fixture.token)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
    }

    func testLoadRejectsContentAddressedPathNotBoundToReceiptDigest() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root.appendingPathComponent("Project.easysplatproj"))
        try paths.ensureDirectories()
        let policy = VideoFrameAnalysisPolicy(targetFrameCeiling: 500, targetFPS: 4)
        let artifact = makeArtifact(policy: policy)
        let saved = try VideoFrameAnalysisArtifactStore.saveRegenerated(
            artifact,
            projectPaths: paths
        )
        let wrongURL = paths.videoFrameAnalysisURL(
            index: 0,
            artifactSHA256: String(repeating: "b", count: 64)
        )
        try Data(contentsOf: saved.url).write(to: wrongURL, options: .atomic)
        let receipt = makeReceipt(
            artifact: artifact,
            fileEvidence: saved.evidence,
            analysisPath: try paths.projectRelativePath(for: wrongURL)
        )

        XCTAssertThrowsError(try VideoFrameAnalysisArtifactStore.load(
            from: wrongURL,
            receipt: receipt,
            expectedPolicy: policy,
            expectedClipGroupID: artifact.clipGroupID,
            expectedSourceIndex: 0,
            projectPaths: paths
        )) { error in
            XCTAssertEqual(error as? VideoFrameAnalysisArtifactStoreError, .unsafePath)
        }
    }

    func testLoadRejectsTamperedSidecarBeforeDecodingPayload() throws {
        let fixture = try makePersistedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var bytes = try Data(contentsOf: fixture.url)
        bytes[bytes.startIndex] ^= 0x01
        try bytes.write(to: fixture.url, options: [.atomic])

        XCTAssertThrowsError(try VideoFrameAnalysisArtifactStore.load(
            from: fixture.url,
            receipt: fixture.receipt,
            expectedPolicy: fixture.policy,
            expectedClipGroupID: "video_000",
            expectedSourceIndex: 0,
            projectPaths: fixture.paths
        )) { error in
            XCTAssertEqual(
                error as? VideoFrameAnalysisArtifactStoreError,
                .artifactDigestMismatch
            )
        }
    }

    func testLoadRejectsStalePolicyAndClipIdentity() throws {
        let fixture = try makePersistedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        XCTAssertThrowsError(try VideoFrameAnalysisArtifactStore.load(
            from: fixture.url,
            receipt: fixture.receipt,
            expectedPolicy: VideoFrameAnalysisPolicy(targetFrameCeiling: 120, targetFPS: 3),
            expectedClipGroupID: "video_000",
            expectedSourceIndex: 0,
            projectPaths: fixture.paths
        )) { error in
            XCTAssertEqual(error as? VideoFrameAnalysisArtifactStoreError, .policyMismatch)
        }

        XCTAssertThrowsError(try VideoFrameAnalysisArtifactStore.load(
            from: fixture.url,
            receipt: fixture.receipt,
            expectedPolicy: fixture.policy,
            expectedClipGroupID: "video_sha256_(fixture.receipt.sha256)",
            expectedSourceIndex: 0,
            projectPaths: fixture.paths
        )) { error in
            XCTAssertEqual(error as? VideoFrameAnalysisArtifactStoreError, .clipIdentityMismatch)
        }
    }

    func testLoadRejectsReceiptBoundToDifferentSource() throws {
        let fixture = try makePersistedFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let changed = makeReceipt(
            artifact: fixture.artifact,
            fileEvidence: fixture.fileEvidence,
            analysisPath: fixture.receipt.analysisArtifactPath,
            sourceSHA256: String(repeating: "b", count: 64)
        )

        XCTAssertThrowsError(try VideoFrameAnalysisArtifactStore.load(
            from: fixture.url,
            receipt: changed,
            expectedPolicy: fixture.policy,
            expectedClipGroupID: "video_000",
            expectedSourceIndex: 0,
            projectPaths: fixture.paths
        )) { error in
            XCTAssertEqual(error as? VideoFrameAnalysisArtifactStoreError, .sourceMismatch)
        }
    }

    private func makePersistedFixture() throws -> (
        root: URL,
        paths: ProjectPaths,
        url: URL,
        policy: VideoFrameAnalysisPolicy,
        artifact: VideoFrameAnalysisArtifact,
        fileEvidence: VideoFrameAnalysisArtifactFileEvidence,
        receipt: VideoInputReceipt
    ) {
        let root = try TestFileBuilder.makeTempDir()
        let paths = ProjectPaths(root: root.appendingPathComponent("Project.easysplatproj"))
        try paths.ensureDirectories()
        let policy = VideoFrameAnalysisPolicy(targetFrameCeiling: 250, targetFPS: 3)
        let artifact = makeArtifact(policy: policy)
        let url = paths.videoFrameAnalysisURL(index: 0)
        let evidence = try VideoFrameAnalysisArtifactStore.save(
            artifact,
            to: url,
            projectPaths: paths
        )
        let receipt = makeReceipt(
            artifact: artifact,
            fileEvidence: evidence,
            analysisPath: try paths.projectRelativePath(for: url)
        )
        return (root, paths, url, policy, artifact, evidence, receipt)
    }

    private func makeRemovalFixture() throws -> (
        root: URL,
        url: URL,
        token: VideoFrameAnalysisArtifactRemovalToken
    ) {
        let root = try TestFileBuilder.makeTempDir()
        let paths = ProjectPaths(root: root.appendingPathComponent("Project.easysplatproj"))
        try paths.ensureDirectories()
        let saved = try VideoFrameAnalysisArtifactStore.saveRegenerated(
            makeArtifact(
                policy: VideoFrameAnalysisPolicy(targetFrameCeiling: 500, targetFPS: 4)
            ),
            projectPaths: paths
        )
        return (root, saved.url, try XCTUnwrap(saved.cleanupToken))
    }

    private func makeArtifact(
        policy: VideoFrameAnalysisPolicy
    ) -> VideoFrameAnalysisArtifact {
        VideoFrameAnalysisArtifact(
            sourceIndex: 0,
            sourceProjectRelativePath: "Originals/video-0000.mov",
            sourceByteCount: 1_024,
            sourceSHA256: String(repeating: "a", count: 64),
            clipGroupID: "video_000",
            policy: policy,
            trackID: 1,
            pixelWidth: 1_920,
            pixelHeight: 1_080,
            durationSeconds: 1,
            nominalFrameRate: 30,
            isHDR: false,
            decodedFrameCount: 30,
            hadRepairedTimestamps: false,
            transformA: 1,
            transformB: 0,
            transformC: 0,
            transformD: 1,
            transformTX: 0,
            transformTY: 0,
            candidates: [
                .init(
                    frameIndex: 0,
                    timestampSeconds: 0,
                    presentationTimeValue: 0,
                    presentationTimeTimescale: 30,
                    sharpness: 0.9,
                    brightness: 0.5,
                    clippedFraction: 0,
                    motionScore: 0,
                    dHash: 0x0101
                ),
                .init(
                    frameIndex: 12,
                    timestampSeconds: 0.4,
                    presentationTimeValue: 12,
                    presentationTimeTimescale: 30,
                    sharpness: 0.8,
                    brightness: 0.6,
                    clippedFraction: 0.01,
                    motionScore: 0.2,
                    dHash: 0x0202
                ),
                .init(
                    frameIndex: 29,
                    timestampSeconds: 29.0 / 30.0,
                    presentationTimeValue: 29,
                    presentationTimeTimescale: 30,
                    sharpness: 0.7,
                    brightness: 0.4,
                    clippedFraction: 0.02,
                    motionScore: 0.1,
                    dHash: 0x0f0f
                ),
            ]
        )
    }

    private func makeReceipt(
        artifact: VideoFrameAnalysisArtifact,
        fileEvidence: VideoFrameAnalysisArtifactFileEvidence,
        analysisPath: String,
        sourceSHA256: String? = nil
    ) -> VideoInputReceipt {
        VideoInputReceipt(
            projectRelativePath: artifact.sourceProjectRelativePath,
            safeDisplayName: "Capture.mov",
            byteCount: artifact.sourceByteCount,
            sha256: sourceSHA256 ?? artifact.sourceSHA256,
            trackID: artifact.trackID,
            pixelWidth: artifact.pixelWidth,
            pixelHeight: artifact.pixelHeight,
            durationSeconds: artifact.durationSeconds,
            nominalFrameRate: artifact.nominalFrameRate,
            isHDR: artifact.isHDR,
            decodedFrameCount: artifact.decodedFrameCount,
            transformA: artifact.transformA,
            transformB: artifact.transformB,
            transformC: artifact.transformC,
            transformD: artifact.transformD,
            transformTX: artifact.transformTX,
            transformTY: artifact.transformTY,
            clipGroupID: artifact.clipGroupID,
            analysisPolicySHA256: artifact.policy.sha256,
            analysisArtifactPath: analysisPath,
            analysisArtifactByteCount: fileEvidence.byteCount,
            analysisArtifactSHA256: fileEvidence.sha256
        )
    }
}
