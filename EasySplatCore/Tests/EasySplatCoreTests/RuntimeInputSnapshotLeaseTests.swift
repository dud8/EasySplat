import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import EasySplatCore

final class RuntimeInputSnapshotLeaseTests: XCTestCase {
    func testSuccessfulPrepareSealsSnapshotsAndRunBeforeDescriptorSafeCleanup() throws {
        let fixture = try makeFixture(
            videos: [Data("video-zero".utf8), Data("video-one".utf8)],
            photos: [Data("photo-zero".utf8), Data("photo-one".utf8)]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try VideoInputReceiptValidator.validateMetadata(
            fixture.metadata,
            paths: fixture.paths
        )
        try PhotoInputReceiptValidator.validateMetadata(
            fixture.metadata,
            paths: fixture.paths
        )
        _ = try PhotoSelectionProjection.loadVerified(
            metadata: fixture.metadata,
            paths: fixture.paths
        )

        let lease = try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths
        )

        XCTAssertEqual(lease.videos.map(\.projectRelativePath), [
            "Originals/video-0000.mov",
            "Originals/video-0001.mov",
        ])
        XCTAssertEqual(lease.photos.map(\.projectRelativePath), [
            "Originals/Photos/photo-0000.jpg",
            "Originals/Photos/photo-0001.jpg",
        ])
        XCTAssertEqual(try lease.videos.map { try Data(contentsOf: $0.url) }, [
            Data("video-zero".utf8),
            Data("video-one".utf8),
        ])
        XCTAssertEqual(try lease.photos.map { try Data(contentsOf: $0.url) }, [
            Data("photo-zero".utf8),
            Data("photo-one".utf8),
        ])
        XCTAssertEqual(try permissions(of: lease.directoryURL), 0o500)
        for snapshot in lease.videos + lease.photos {
            XCTAssertEqual(try permissions(of: snapshot.url), 0o400)
            XCTAssertNotEqual(snapshot.url, try fixture.paths.resolveProjectRelativePath(
                snapshot.projectRelativePath
            ))

            errno = 0
            let writeDescriptor = Darwin.open(snapshot.url.path, O_WRONLY | O_CLOEXEC)
            if writeDescriptor >= 0 { Darwin.close(writeDescriptor) }
            XCTAssertEqual(writeDescriptor, -1, "A sealed runtime snapshot must not open for writing")
        }

        let runURL = lease.directoryURL
        let firstSnapshot = try XCTUnwrap((lease.videos + lease.photos).first)
        let renamedURL = runURL.appendingPathComponent("renamed-input")
        errno = 0
        XCTAssertEqual(
            Darwin.rename(firstSnapshot.url.path, renamedURL.path),
            -1,
            "A sealed run directory must reject renaming a snapshot"
        )

        let unexpectedURL = runURL.appendingPathComponent("unexpected-input")
        errno = 0
        let createdDescriptor = Darwin.open(
            unexpectedURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            S_IRUSR
        )
        if createdDescriptor >= 0 { Darwin.close(createdDescriptor) }
        XCTAssertEqual(
            createdDescriptor,
            -1,
            "A sealed run directory must reject creating another entry"
        )

        lease.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: runURL.path))
    }

    func testValidateRejectsTamperedRunModeAndDiscardPreservesIt() throws {
        let fixture = try makeFixture(videos: [Data("receipted".utf8)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lease = try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths
        )
        let runURL = lease.directoryURL
        XCTAssertEqual(try permissions(of: runURL), 0o500)

        try setPermissions(0o700, of: runURL)
        XCTAssertThrowsError(try lease.validate()) { error in
            XCTAssertEqual(error as? RuntimeInputSnapshotError, .leaseUnavailable)
        }

        lease.discard()
        let runStillExists = FileManager.default.fileExists(atPath: runURL.path)
        XCTAssertTrue(runStillExists)
        if runStillExists {
            XCTAssertEqual(try permissions(of: runURL), 0o700)
        }
    }

    func testValidateRejectsTamperedSnapshotModeAndDiscardPreservesAllEvidence() throws {
        let fixture = try makeFixture(videos: [Data("receipted".utf8)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lease = try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths
        )
        let runURL = lease.directoryURL
        let snapshotURL = try XCTUnwrap(lease.videos.first?.url)
        XCTAssertEqual(try permissions(of: runURL), 0o500)
        XCTAssertEqual(try permissions(of: snapshotURL), 0o400)

        try setPermissions(0o600, of: snapshotURL)
        XCTAssertThrowsError(try lease.validate()) { error in
            XCTAssertEqual(error as? RuntimeInputSnapshotError, .leaseUnavailable)
        }

        lease.discard()
        let runStillExists = FileManager.default.fileExists(atPath: runURL.path)
        let snapshotStillExists = FileManager.default.fileExists(atPath: snapshotURL.path)
        XCTAssertTrue(runStillExists)
        XCTAssertTrue(snapshotStillExists)
        if runStillExists {
            XCTAssertEqual(try permissions(of: runURL), 0o500)
        }
        if snapshotStillExists {
            XCTAssertEqual(try permissions(of: snapshotURL), 0o600)
        }
    }

    func testValidateRejectsProjectRootRebindForVideoOnlyLease() throws {
        let fixture = try makeFixture(videos: [Data("receipted".utf8)])
        let heldRoot = fixture.root.deletingLastPathComponent().appendingPathComponent(
            "\(fixture.root.lastPathComponent)-held-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: heldRoot)
        }
        let lease = try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths
        )
        defer { lease.discard() }

        XCTAssertEqual(Darwin.rename(fixture.root.path, heldRoot.path), 0)
        try FileManager.default.createDirectory(
            at: fixture.root,
            withIntermediateDirectories: false
        )

        XCTAssertThrowsError(try lease.validate()) { error in
            XCTAssertEqual(error as? RuntimeInputSnapshotError, .leaseUnavailable)
        }
    }

    func testPrepareRejectsProjectRootRebindAfterVideoSnapshot() throws {
        let fixture = try makeFixture(videos: [Data("receipted".utf8)])
        let heldRoot = fixture.root.deletingLastPathComponent().appendingPathComponent(
            "\(fixture.root.lastPathComponent)-held-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: fixture.root)
            try? FileManager.default.removeItem(at: heldRoot)
        }
        let rebindCount = CallCounter()

        XCTAssertThrowsError(try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths,
            cloneSnapshot: { source, destinationDirectory, leaf in
                let result = leaf.withCString {
                    fclonefileat(
                        source,
                        destinationDirectory,
                        $0,
                        UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)
                    )
                }
                guard result == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                rebindCount.record()
                XCTAssertEqual(Darwin.rename(fixture.root.path, heldRoot.path), 0)
                try FileManager.default.createDirectory(
                    at: fixture.root,
                    withIntermediateDirectories: false
                )
                return true
            }
        )) { error in
            XCTAssertEqual(error as? RuntimeInputSnapshotError, .leaseUnavailable)
        }
        XCTAssertEqual(rebindCount.value, 1)
    }

    func testRejectsReceiptMismatchAfterEntryValidation() throws {
        let fixture = try makeFixture(videos: [Data("receipted".utf8)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try VideoInputReceiptValidator.validateFiles(
            metadata: fixture.metadata,
            paths: fixture.paths
        )
        let controlled = try fixture.paths.resolveProjectRelativePath(
            fixture.metadata.videoInputReceipts![0].projectRelativePath
        )
        let replacement = fixture.root.appendingPathComponent("replacement.mov")
        try Data("attacker!".utf8).write(to: replacement)
        try setPrivateFileMode(replacement)
        XCTAssertEqual(Darwin.rename(replacement.path, controlled.path), 0)

        XCTAssertThrowsError(try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths
        )) { error in
            XCTAssertEqual(
                error as? RuntimeInputSnapshotError,
                .digestMismatch(kind: .video, index: 0)
            )
        }
    }

    func testDescriptorCloneRejectsSwapAndRestoreIdentityChurn() throws {
        let fixture = try makeFixture(videos: [Data("receipted".utf8)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controlled = try fixture.paths.resolveProjectRelativePath(
            fixture.metadata.videoInputReceipts![0].projectRelativePath
        )
        let held = fixture.root.appendingPathComponent("held.mov")
        let attacker = fixture.root.appendingPathComponent("attacker.mov")
        try Data("attacker!".utf8).write(to: attacker)
        try setPrivateFileMode(attacker)

        XCTAssertThrowsError(try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths,
            cloneSnapshot: { source, destinationDirectory, leaf in
                XCTAssertEqual(Darwin.rename(controlled.path, held.path), 0)
                XCTAssertEqual(Darwin.rename(attacker.path, controlled.path), 0)
                let result = leaf.withCString {
                    fclonefileat(
                        source,
                        destinationDirectory,
                        $0,
                        UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)
                    )
                }
                XCTAssertEqual(Darwin.rename(controlled.path, attacker.path), 0)
                XCTAssertEqual(Darwin.rename(held.path, controlled.path), 0)
                guard result == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                return true
            }
        )) { error in
            XCTAssertEqual(
                error as? RuntimeInputSnapshotError,
                .sourceChanged(kind: .video, index: 0)
            )
        }
        XCTAssertEqual(try Data(contentsOf: controlled), Data("receipted".utf8))
    }

    func testRejectsPathSwapThatRemainsAfterDescriptorClone() throws {
        let fixture = try makeFixture(videos: [Data("receipted".utf8)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let controlled = try fixture.paths.resolveProjectRelativePath(
            fixture.metadata.videoInputReceipts![0].projectRelativePath
        )
        let held = fixture.root.appendingPathComponent("held.mov")
        let attacker = fixture.root.appendingPathComponent("attacker.mov")
        try Data("attacker!".utf8).write(to: attacker)
        try setPrivateFileMode(attacker)

        XCTAssertThrowsError(try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths,
            cloneSnapshot: { source, destinationDirectory, leaf in
                let result = leaf.withCString {
                    fclonefileat(
                        source,
                        destinationDirectory,
                        $0,
                        UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)
                    )
                }
                guard result == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                XCTAssertEqual(Darwin.rename(controlled.path, held.path), 0)
                XCTAssertEqual(Darwin.rename(attacker.path, controlled.path), 0)
                return true
            }
        )) { error in
            XCTAssertEqual(
                error as? RuntimeInputSnapshotError,
                .sourceChanged(kind: .video, index: 0)
            )
        }
    }

    func testBoundedDescriptorCopyFallbackPreservesBytes() throws {
        let fixture = try makeFixture(
            videos: [Data(repeating: 0x5a, count: 2_100_000)],
            photos: [Data(repeating: 0xa5, count: 1_100_000)]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lease = try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths,
            cloneSnapshot: { _, _, _ in false }
        )
        defer { lease.discard() }

        XCTAssertEqual(try Data(contentsOf: lease.videos[0].url), Data(repeating: 0x5a, count: 2_100_000))
        XCTAssertEqual(try Data(contentsOf: lease.photos[0].url), Data(repeating: 0xa5, count: 1_100_000))
    }

    func testFallbackAcceptsExactLowerCapacityBeforeCreatingDestination() throws {
        let bytes = Data(repeating: 0x37, count: 4_096)
        let required = Int64(bytes.count)
        let fixture = try makeFixture(videos: [bytes])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let leasesRoot = fixture.root.appendingPathComponent(
            ".runtime-input-leases",
            isDirectory: true
        )
        let cloneProbe = CallCounter()
        let probe = CallCounter()

        let lease = try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths,
            cloneSnapshot: { _, _, _ in
                cloneProbe.record()
                return false
            },
            availableCapacity: { _ in
                probe.record()
                XCTAssertEqual(cloneProbe.value, 1)
                XCTAssertEqual(runtimeLeaseRegularFileCount(in: leasesRoot), 0)
                return (ordinary: required + 1_024, important: required)
            }
        )

        XCTAssertEqual(cloneProbe.value, 1)
        XCTAssertEqual(probe.value, 1)
        XCTAssertEqual(try Data(contentsOf: lease.videos[0].url), bytes)
        lease.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: leasesRoot.path))
    }

    func testLeaseCarriesAuthenticatedPhotoRankProjection() throws {
        let fixture = try makeFixture(
            photos: [Data("ranked-a".utf8), Data("ranked-b".utf8), Data("ranked-c".utf8)]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let lease = try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths
        )
        defer { lease.discard() }

        let projection = try XCTUnwrap(lease.photoSelectionProjection)
        XCTAssertEqual(projection.rankOrderedReceipts.map(\.retainedRank), [0, 1, 2])
        XCTAssertEqual(
            try projection.project(targetCount: 2).map(\.source.sha256),
            Array(projection.artifact.retainedSourceSHA256s.prefix(2))
        )
    }

    func testPrepareLoadsPhotoSelectionProjectionOnceAndReusesLeaseEvidence() throws {
        let fixture = try makeFixture(photos: [Data("photo".utf8)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let projectionLoadCount = CallCounter()

        let lease = try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths,
            loadPhotoSelectionProjection: { metadata, paths in
                projectionLoadCount.record()
                return try PhotoSelectionProjection.loadProjectBoundVerified(
                    metadata: metadata,
                    paths: paths
                )
            }
        )
        defer { lease.discard() }

        XCTAssertEqual(projectionLoadCount.value, 1)
        XCTAssertNoThrow(try lease.validate())
        XCTAssertEqual(
            projectionLoadCount.value,
            1,
            "Lease validation must not invoke the projection loader again"
        )
    }

    func testRuntimeReceiptDigestBindsPhotoRankSourceAndSelectionArtifact() throws {
        let fixture = try makeFixture(
            photos: [Data("digest-a".utf8), Data("digest-b".utf8)]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let pairingPolicy = try XCTUnwrap(fixture.metadata.resolvedRunPlan?.pairingPolicy)
        let baseline = try RuntimeInputSnapshotLease.receiptDigest(
            metadata: fixture.metadata,
            pairingPolicy: pairingPolicy
        )

        var rankChanged = fixture.metadata
        var rankReceipts = try XCTUnwrap(rankChanged.photoInputReceipts)
        let firstRank = rankReceipts[0].retainedRank
        rankReceipts[0] = replacingPhotoReceipt(
            rankReceipts[0],
            retainedRank: rankReceipts[1].retainedRank
        )
        rankReceipts[1] = replacingPhotoReceipt(
            rankReceipts[1],
            retainedRank: firstRank
        )
        rankChanged.photoInputReceipts = rankReceipts
        XCTAssertNotEqual(
            baseline,
            try RuntimeInputSnapshotLease.receiptDigest(
                metadata: rankChanged,
                pairingPolicy: pairingPolicy
            )
        )

        var sourceChanged = fixture.metadata
        var sourceReceipts = try XCTUnwrap(sourceChanged.photoInputReceipts)
        sourceReceipts[0] = replacingPhotoReceipt(
            sourceReceipts[0],
            sourceSHA256: String(repeating: "b", count: 64)
        )
        sourceChanged.photoInputReceipts = sourceReceipts
        XCTAssertNotEqual(
            baseline,
            try RuntimeInputSnapshotLease.receiptDigest(
                metadata: sourceChanged,
                pairingPolicy: pairingPolicy
            )
        )

        var artifactChanged = fixture.metadata
        artifactChanged.photoSelectionReceipt = replacingSelectionReceipt(
            try XCTUnwrap(artifactChanged.photoSelectionReceipt),
            sha256: String(repeating: "c", count: 64)
        )
        XCTAssertNotEqual(
            baseline,
            try RuntimeInputSnapshotLease.receiptDigest(
                metadata: artifactChanged,
                pairingPolicy: pairingPolicy
            )
        )
    }

    func testPrepareRejectsChangedPhotoSelectionArtifact() throws {
        let fixture = try makeFixture(photos: [Data("photo".utf8)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var data = try Data(contentsOf: fixture.paths.photoSelectionArtifactURL)
        data[data.startIndex] ^= 0x01
        try data.write(to: fixture.paths.photoSelectionArtifactURL, options: [.atomic])
        try setPrivateFileMode(fixture.paths.photoSelectionArtifactURL)

        XCTAssertThrowsError(try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths
        )) { error in
            XCTAssertEqual(error as? RuntimeInputSnapshotError, .invalidMetadata)
        }
    }

    func testPrepareRejectsMissingPhotoSelectionArtifact() throws {
        let fixture = try makeFixture(photos: [Data("photo".utf8)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(at: fixture.paths.photoSelectionArtifactURL)

        XCTAssertThrowsError(try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths
        )) { error in
            XCTAssertEqual(error as? RuntimeInputSnapshotError, .invalidMetadata)
        }
    }

    func testPrepareRejectsSymlinkedPhotoSelectionArtifact() throws {
        let fixture = try makeFixture(photos: [Data("photo".utf8)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let artifactURL = fixture.paths.photoSelectionArtifactURL
        let target = fixture.root.appendingPathComponent("selection-target.json")
        try FileManager.default.moveItem(at: artifactURL, to: target)
        try FileManager.default.createSymbolicLink(
            at: artifactURL,
            withDestinationURL: target
        )

        XCTAssertThrowsError(try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths
        )) { error in
            XCTAssertEqual(error as? RuntimeInputSnapshotError, .invalidMetadata)
        }
    }

    func testPrepareRejectsNonprivatePhotoSelectionArtifact() throws {
        let fixture = try makeFixture(photos: [Data("photo".utf8)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try setPermissions(0o644, of: fixture.paths.photoSelectionArtifactURL)

        XCTAssertThrowsError(try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths
        )) { error in
            XCTAssertEqual(error as? RuntimeInputSnapshotError, .invalidMetadata)
        }
    }

    func testPrepareRejectsPhotoSelectionReplacementAfterInitialLoad() throws {
        let fixture = try makeFixture(photos: [Data("photo".utf8)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let artifactURL = fixture.paths.photoSelectionArtifactURL
        let artifactData = try Data(contentsOf: artifactURL)
        let mutationCount = CallCounter()

        XCTAssertThrowsError(try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths,
            cloneSnapshot: { _, _, _ in
                if mutationCount.value == 0 {
                    mutationCount.record()
                    try artifactData.write(to: artifactURL, options: [.atomic])
                    try self.setPrivateFileMode(artifactURL)
                }
                return false
            }
        )) { error in
            XCTAssertEqual(error as? RuntimeInputSnapshotError, .invalidMetadata)
        }
        XCTAssertEqual(mutationCount.value, 1)
    }

    func testValidateRejectsPhotoSelectionArtifactReplacementWithIdenticalBytes() throws {
        let fixture = try makeFixture(photos: [Data("photo".utf8)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lease = try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths
        )
        defer { lease.discard() }
        let artifactURL = fixture.paths.photoSelectionArtifactURL
        let data = try Data(contentsOf: artifactURL)
        try data.write(to: artifactURL, options: [.atomic])
        try setPrivateFileMode(artifactURL)

        XCTAssertThrowsError(try lease.validate()) { error in
            XCTAssertEqual(error as? RuntimeInputSnapshotError, .leaseUnavailable)
        }
    }

    func testValidateRejectsPhotoSelectionArtifactModeMutation() throws {
        let fixture = try makeFixture(photos: [Data("photo".utf8)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lease = try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths
        )
        defer { lease.discard() }
        try setPermissions(0o644, of: fixture.paths.photoSelectionArtifactURL)

        XCTAssertThrowsError(try lease.validate()) { error in
            XCTAssertEqual(error as? RuntimeInputSnapshotError, .leaseUnavailable)
        }
    }

    func testValidateRejectsPhotoSelectionFramesDirectoryRebind() throws {
        let fixture = try makeFixture(photos: [Data("photo".utf8)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lease = try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths
        )
        defer { lease.discard() }
        let frames = fixture.root.appendingPathComponent("Frames", isDirectory: true)
        let heldFrames = fixture.root.appendingPathComponent("Frames-held", isDirectory: true)
        XCTAssertEqual(Darwin.rename(frames.path, heldFrames.path), 0)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: false)
        try FileManager.default.moveItem(
            at: heldFrames.appendingPathComponent("photo_selection.json"),
            to: frames.appendingPathComponent("photo_selection.json")
        )

        XCTAssertThrowsError(try lease.validate()) { error in
            XCTAssertEqual(error as? RuntimeInputSnapshotError, .leaseUnavailable)
        }
    }

    func testEmptyMixedInputRequiresNoPhotoSelectionSidecar() throws {
        let fixture = try makeFixture(
            videos: [Data("video".utf8)],
            forceEmptyMixed: true
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let lease = try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths
        )
        defer { lease.discard() }

        XCTAssertNil(lease.photoSelectionProjection)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.paths.photoSelectionArtifactURL.path
        ))
        XCTAssertNoThrow(try lease.validate())
    }

    func testRuntimeReceiptDigestRejectsMissingResolvedPairingPolicy() throws {
        let fixture = try makeFixture(videos: [Data("video".utf8)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var metadata = fixture.metadata
        metadata.resolvedRunPlan = nil

        XCTAssertThrowsError(try RuntimeInputSnapshotLease.receiptDigest(
            metadata: metadata
        )) { error in
            XCTAssertEqual(error as? RuntimeInputSnapshotError, .invalidMetadata)
        }
    }

    func testFallbackRejectsOneByteShortLowerCapacityBeforeCreatingDestination() throws {
        let bytes = Data(repeating: 0x73, count: 4_096)
        let required = Int64(bytes.count)
        let fixture = try makeFixture(videos: [bytes])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let leasesRoot = fixture.root.appendingPathComponent(
            ".runtime-input-leases",
            isDirectory: true
        )
        let probe = CallCounter()

        XCTAssertThrowsError(try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths,
            cloneSnapshot: { _, _, _ in false },
            availableCapacity: { _ in
                probe.record()
                XCTAssertEqual(runtimeLeaseRegularFileCount(in: leasesRoot), 0)
                return (ordinary: required + 1_024, important: required - 1)
            }
        )) { error in
            XCTAssertNotNil(error as? RuntimeInputSnapshotError)
        }

        XCTAssertEqual(probe.value, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leasesRoot.path))
    }

    func testFallbackFailsClosedForUnavailableOrNegativeCapacityEvidence() throws {
        let bytes = Data(repeating: 0x4c, count: 4_096)
        let required = Int64(bytes.count)
        let cases: [(name: String, ordinary: Int64?, important: Int64?)] = [
            ("unavailable", nil, nil),
            ("negative", -1, required + 1_024),
        ]

        for evidence in cases {
            let fixture = try makeFixture(videos: [bytes])
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let leasesRoot = fixture.root.appendingPathComponent(
                ".runtime-input-leases",
                isDirectory: true
            )
            let probe = CallCounter()

            XCTAssertThrowsError(try RuntimeInputSnapshotLease.prepare(
                metadata: fixture.metadata,
                paths: fixture.paths,
                cloneSnapshot: { _, _, _ in false },
                availableCapacity: { _ in
                    probe.record()
                    XCTAssertEqual(
                        runtimeLeaseRegularFileCount(in: leasesRoot),
                        0,
                        "\(evidence.name) capacity was checked after destination creation"
                    )
                    return (ordinary: evidence.ordinary, important: evidence.important)
                }
            )) { error in
                XCTAssertNotNil(error as? RuntimeInputSnapshotError, evidence.name)
            }

            XCTAssertEqual(probe.value, 1, evidence.name)
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: leasesRoot.path),
                evidence.name
            )
        }
    }

    func testFallbackLowDiskFailureRemovesOnlyTheBoundRun() throws {
        let fixture = try makeFixture(videos: [Data(repeating: 0x6b, count: 1_100_000)])
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let leasesRoot = fixture.root.appendingPathComponent(
            ".runtime-input-leases",
            isDirectory: true
        )

        XCTAssertThrowsError(try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths,
            cloneSnapshot: { _, _, _ in false },
            writeChunk: { _, _, _ in
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))
            }
        )) { error in
            XCTAssertEqual(
                error as? RuntimeInputSnapshotError,
                .copyFailed(kind: .video, index: 0)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: leasesRoot.path))
    }

    func testCancellationCleansCompletedAndPartialSnapshots() throws {
        let fixture = try makeFixture(
            videos: [Data(repeating: 1, count: 1_100_000), Data(repeating: 2, count: 64)]
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cloneAttempts = CallCounter()
        let partialWrites = CallCounter()

        XCTAssertThrowsError(try RuntimeInputSnapshotLease.prepare(
            metadata: fixture.metadata,
            paths: fixture.paths,
            cloneSnapshot: { _, _, _ in
                cloneAttempts.record()
                return false
            },
            checkCancellation: {
                if cloneAttempts.value == 2, partialWrites.value > 0 {
                    throw CancellationError()
                }
            },
            writeChunk: { descriptor, bytes, count in
                let writeCount = cloneAttempts.value == 2 ? min(count, 1) : count
                let result = Darwin.write(descriptor, bytes, writeCount)
                if cloneAttempts.value == 2, result > 0 {
                    partialWrites.record()
                }
                return result
            }
        )) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(cloneAttempts.value, 2)
        XCTAssertEqual(partialWrites.value, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root
            .appendingPathComponent(".runtime-input-leases").path))
    }

    func testRejectsSymlinkHardLinkAndSpecialFileSources() throws {
        for mutation in SourceMutation.allCases {
            let fixture = try makeFixture(videos: [Data("receipted".utf8)])
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let controlled = try fixture.paths.resolveProjectRelativePath(
                fixture.metadata.videoInputReceipts![0].projectRelativePath
            )
            try FileManager.default.removeItem(at: controlled)
            switch mutation {
            case .symlink:
                let target = fixture.root.appendingPathComponent("target.mov")
                try Data("receipted".utf8).write(to: target)
                try setPrivateFileMode(target)
                try FileManager.default.createSymbolicLink(at: controlled, withDestinationURL: target)
            case .hardLink:
                let target = fixture.root.appendingPathComponent("target.mov")
                try Data("receipted".utf8).write(to: target)
                try setPrivateFileMode(target)
                try FileManager.default.linkItem(at: target, to: controlled)
            case .fifo:
                XCTAssertEqual(mkfifo(controlled.path, S_IRUSR | S_IWUSR), 0)
            }

            XCTAssertThrowsError(try RuntimeInputSnapshotLease.prepare(
                metadata: fixture.metadata,
                paths: fixture.paths
            )) { error in
                guard let snapshotError = error as? RuntimeInputSnapshotError else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertTrue(
                    [
                        RuntimeInputSnapshotError.invalidMetadata,
                        .unsafeSource(kind: .video, index: 0),
                    ].contains(snapshotError)
                )
            }
        }
    }

    private enum SourceMutation: CaseIterable {
        case symlink
        case hardLink
        case fifo
    }

    private struct Fixture {
        let root: URL
        let paths: ProjectPaths
        let metadata: ProjectMetadata
    }

    private func makeFixture(
        videos: [Data] = [],
        photos: [Data] = [],
        forceEmptyMixed: Bool = false
    ) throws -> Fixture {
        let root = try TestFileBuilder.makeTempDir()
        let paths = ProjectPaths(root: root)
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(
            at: paths.importedPhotosURL,
            withIntermediateDirectories: true
        )
        let fixturePairingPolicy: ResolvedPairingPolicy = forceEmptyMixed
            || videos.count > 1 || !photos.isEmpty
            ? .segmentedMixed
            : .orderedContinuous
        let videoIdentities = try VideoClipIdentityResolver.resolve(
            sourceSHA256s: videos.map(sha256),
            pairingPolicy: fixturePairingPolicy
        )
        let clipGroupIDBySourceIndex = Dictionary(
            uniqueKeysWithValues: videoIdentities.map {
                ($0.sourceIndex, $0.groupID)
            }
        )
        var videoReceipts: [VideoInputReceipt] = []
        for (index, bytes) in videos.enumerated() {
            videoReceipts.append(try TestFileBuilder.writeControlledVideoReceipt(
                paths: paths,
                index: index,
                bytes: bytes,
                safeDisplayName: "Video \(index + 1).mov",
                clipGroupID: try XCTUnwrap(clipGroupIDBySourceIndex[index])
            ).receipt)
        }
        let canonicalPhotos = photos.map { bytes in
            (bytes: bytes, digest: sha256(bytes))
        }.sorted { $0.digest < $1.digest }
        let photoEvidence = canonicalPhotos.map { photo in
            TestFileBuilder.photoAnalysisEvidence(
                sourceSHA256: photo.digest,
                seed: UInt8(photo.digest.prefix(2), radix: 16) ?? 0
            )
        }
        let rankedPhotoEvidence = try PhotoDiversitySelector.rank(
            photoEvidence,
            targetCount: photoEvidence.count
        )
        let photoRankBySHA256 = Dictionary(
            uniqueKeysWithValues: rankedPhotoEvidence.enumerated().map {
                ($0.element.sourceSHA256, $0.offset)
            }
        )
        var photoReceipts: [PhotoInputReceipt] = []
        for (index, photo) in canonicalPhotos.enumerated() {
            let relativePath = String(format: "Originals/Photos/photo-%04d.jpg", index)
            let url = try paths.resolveProjectRelativePath(relativePath)
            try photo.bytes.write(to: url)
            try setPrivateFileMode(url)
            photoReceipts.append(PhotoInputReceipt(
                projectRelativePath: relativePath,
                safeDisplayName: "Photo \(index + 1).jpg",
                byteCount: Int64(photo.bytes.count),
                sha256: photo.digest,
                pixelWidth: 16,
                pixelHeight: 16,
                orientation: 1,
                typeIdentifier: "public.jpeg",
                analysisEvidence: photoEvidence[index],
                retainedRank: try XCTUnwrap(photoRankBySHA256[photo.digest])
            ))
        }
        let input: InputSpec
        switch (videos.isEmpty, photos.isEmpty, forceEmptyMixed) {
        case (false, true, true):
            input = .mixed(
                videos: videoReceipts.map(\.projectRelativePath),
                photosFolder: "Originals/Photos"
            )
        case (false, false, _):
            input = .mixed(
                videos: videoReceipts.map(\.projectRelativePath),
                photosFolder: "Originals/Photos"
            )
        case (false, true, false):
            input = .video(files: videoReceipts.map(\.projectRelativePath))
        case (true, false, _):
            input = .photos(folder: "Originals/Photos")
        case (true, true, _):
            throw NSError(domain: "RuntimeInputSnapshotLeaseTests", code: 1)
        }
        let requestedOptions = RequestedRunOptions(detailProfile: .fast)
        let resolvedRunPlan = RunPlanResolver.resolve(
            requestedOptions: requestedOptions,
            input: input,
            hardware: HardwareProfile(
                memoryGB: 48,
                cpuCount: 16,
                gpuWorkingSetGB: 36
            ),
            developmentOverrides: .none
        )
        let photoSelectionReceipt: PhotoSelectionReceipt?
        if photoReceipts.isEmpty {
            photoSelectionReceipt = nil
        } else {
            let retainedSHA256s = rankedPhotoEvidence.map(\.sourceSHA256)
            let artifact = PhotoSelectionArtifact(
                strategy: .visualDiversity,
                analysisRecipeVersion: PhotoAnalysisEvidenceBuilder.recipeVersion,
                analysisRecipeSHA256: PhotoAnalysisEvidenceBuilder.recipeSHA256,
                selectorPolicyVersion: PhotoDiversitySelector.selectorPolicyVersion,
                selectorPolicySHA256: PhotoDiversitySelector.selectorPolicySHA256,
                inputOrdering: resolvedRunPlan.inputOrdering,
                requestedPhotoSelection: resolvedRunPlan.photoSelection,
                admissionCapacity: photoEvidence.count,
                discoveredCount: photoEvidence.count,
                acceptedCount: photoEvidence.count,
                unreadableCount: 0,
                exactDuplicateCount: 0,
                companionDuplicateCount: 0,
                candidates: photoEvidence.enumerated().map { index, evidence in
                    PhotoSelectionCandidateArtifact(
                        admissionOrdinal: index,
                        evidence: evidence,
                        retainedRank: photoRankBySHA256[evidence.sourceSHA256]
                    )
                },
                retainedSourceSHA256s: retainedSHA256s,
                canonicalRetainedSourceSHA256s: retainedSHA256s.sorted()
            )
            let file = try PhotoSelectionArtifactStore.save(
                artifact,
                to: paths.photoSelectionArtifactURL,
                projectPaths: paths
            )
            photoSelectionReceipt = PhotoSelectionReceipt(
                projectRelativePath: PhotoSelectionReceipt.projectRelativePath,
                byteCount: file.byteCount,
                sha256: file.sha256,
                artifactSchemaVersion: artifact.schemaVersion,
                analysisRecipeVersion: artifact.analysisRecipeVersion,
                analysisRecipeSHA256: artifact.analysisRecipeSHA256,
                selectorPolicyVersion: artifact.selectorPolicyVersion,
                selectorPolicySHA256: artifact.selectorPolicySHA256
            )
        }
        return Fixture(
            root: root,
            paths: paths,
            metadata: ProjectMetadata(
                title: "Runtime input lease",
                input: input,
                videoInputReceipts: videos.isEmpty ? nil : videoReceipts,
                photoInputReceipts: photos.isEmpty && !forceEmptyMixed
                    ? nil
                    : photoReceipts,
                photoSelectionReceipt: photoSelectionReceipt,
                requestedRunOptions: requestedOptions,
                resolvedRunPlan: resolvedRunPlan
            )
        )
    }

    private func setPrivateFileMode(_ url: URL) throws {
        try setPermissions(0o600, of: url)
    }

    private func replacingPhotoReceipt(
        _ receipt: PhotoInputReceipt,
        sourceSHA256: String? = nil,
        retainedRank: Int? = nil
    ) -> PhotoInputReceipt {
        let resolvedSourceSHA256 = sourceSHA256 ?? receipt.source.sha256
        let evidence = PhotoAnalysisEvidence(
            sourceSHA256: resolvedSourceSHA256,
            spatialDescriptor: receipt.analysisEvidence.spatialDescriptor,
            qualityBucket: receipt.analysisEvidence.qualityBucket,
            dHash: receipt.analysisEvidence.dHash,
            proxyPixelWidth: receipt.analysisEvidence.proxyPixelWidth,
            proxyPixelHeight: receipt.analysisEvidence.proxyPixelHeight,
            proxyPixelSHA256: receipt.analysisEvidence.proxyPixelSHA256,
            analysisRecipeVersion: receipt.analysisEvidence.analysisRecipeVersion,
            analysisRecipeSHA256: receipt.analysisEvidence.analysisRecipeSHA256
        )
        return PhotoInputReceipt(
            schemaVersion: receipt.schemaVersion,
            projectRelativePath: receipt.projectRelativePath,
            safeDisplayName: receipt.safeDisplayName,
            byteCount: receipt.byteCount,
            sha256: receipt.sha256,
            pixelWidth: receipt.pixelWidth,
            pixelHeight: receipt.pixelHeight,
            orientation: receipt.orientation,
            typeIdentifier: receipt.typeIdentifier,
            source: PhotoSourceProvenance(
                byteCount: receipt.source.byteCount,
                sha256: resolvedSourceSHA256,
                typeIdentifier: receipt.source.typeIdentifier
            ),
            importMode: receipt.importMode,
            analysisEvidence: evidence,
            retainedRank: retainedRank ?? receipt.retainedRank
        )
    }

    private func replacingSelectionReceipt(
        _ receipt: PhotoSelectionReceipt,
        sha256: String
    ) -> PhotoSelectionReceipt {
        PhotoSelectionReceipt(
            schemaVersion: receipt.schemaVersion,
            projectRelativePath: receipt.projectRelativePath,
            byteCount: receipt.byteCount,
            sha256: sha256,
            artifactSchemaVersion: receipt.artifactSchemaVersion,
            analysisRecipeVersion: receipt.analysisRecipeVersion,
            analysisRecipeSHA256: receipt.analysisRecipeSHA256,
            selectorPolicyVersion: receipt.selectorPolicyVersion,
            selectorPolicySHA256: receipt.selectorPolicySHA256
        )
    }

    private func setPermissions(_ mode: Int, of url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func record() {
        lock.withLock { count += 1 }
    }
}

private func runtimeLeaseRegularFileCount(in leasesRoot: URL) -> Int {
    guard let enumerator = FileManager.default.enumerator(
        at: leasesRoot,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else {
        return 0
    }
    var count = 0
    for case let url as URL in enumerator {
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            count += 1
        }
    }
    return count
}
