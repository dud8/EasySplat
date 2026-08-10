import Darwin
import XCTest
@testable import EasySplatCore

final class SplatExportTests: XCTestCase {
    func testCopyIfExistsPreservesExistingOutputWhenSourceCopyFails() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("splat.ply")
        try TestFileBuilder.writeMinimalPly(at: destination)
        let before = try Data(contentsOf: destination)

        XCTAssertThrowsError(
            try SplatExport.copyIfExists(from: root.appendingPathComponent("missing.ply"), to: destination)
        )

        XCTAssertEqual(try Data(contentsOf: destination), before)
    }

    func testCopyIfExistsReplacesOutputAtomicallyAfterSuccessfulCopy() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("export_00002.ply")
        let destination = root.appendingPathComponent("splat.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        try TestFileBuilder.writeMinimalPly(at: destination, vertexCount: 1)

        try SplatExport.copyIfExists(from: source, to: destination)

        let text = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(text.contains("element vertex 2"))
    }

    func testCopyIfExistsPreservesExistingOutputWhenSourceIsCorrupt() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("corrupt.ply")
        let destination = root.appendingPathComponent("splat.ply")
        try Data("ply\nformat ascii 1.0\n".utf8).write(to: source)
        try TestFileBuilder.writeMinimalPly(at: destination)
        let before = try Data(contentsOf: destination)

        XCTAssertThrowsError(try SplatExport.copyIfExists(from: source, to: destination))

        XCTAssertEqual(try Data(contentsOf: destination), before)
    }
}

extension SplatExportTests {
    /// The user-selected path cannot open the destination's directory, so it has
    /// to produce the same bytes through a descriptor-bound exclusive clone.
    func testUserSelectedPublicationMatchesTheProjectOwnedResult() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)

        let owned = root.appendingPathComponent("owned.ply")
        let chosen = root.appendingPathComponent("chosen.ply")
        let ownedEvidence = try ProjectArtifactValidator.publishValidatedPly(
            from: source,
            to: owned
        )
        let chosenEvidence = try ProjectArtifactValidator.publishValidatedPly(
            from: source,
            to: chosen,
            destinationKind: .userSelected
        )

        XCTAssertEqual(ownedEvidence, chosenEvidence)
        XCTAssertEqual(try Data(contentsOf: owned), try Data(contentsOf: chosen))
    }

    func testUserSelectedPublicationReplacesStableDifferentExistingFile() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("existing.ply")
        try Data("stale bytes that are not a ply".utf8).write(to: destination)
        XCTAssertEqual(Darwin.chmod(destination.path, 0o644), 0)

        let expected = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        let published = try ProjectArtifactValidator.publishValidatedPly(
            from: source,
            to: destination,
            destinationKind: .userSelected
        )

        XCTAssertEqual(published, expected)
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
        var publishedMetadata = stat()
        XCTAssertEqual(lstat(destination.path, &publishedMetadata), 0)
        XCTAssertEqual(publishedMetadata.st_mode & 0o777, 0o644)
    }

    func testUserSelectedUnsupportedCloneFallsBackToAbsentMove() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("chosen.ply")
        var operations = UserSelectedPlyPublicationFileOperations.system()
        operations.cloneAbsent = { _, _ in
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP))
        }
        let moveAbsent = operations.moveAbsent
        var moveWasCalled = false
        operations.moveAbsent = { candidate, selected in
            moveWasCalled = true
            try moveAbsent(candidate, selected)
        }

        let published = try publishUserSelected(
            source: source,
            destination: destination,
            fileOperations: operations
        )

        XCTAssertTrue(moveWasCalled)
        XCTAssertEqual(
            published,
            try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        )
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
    }

    func testUserSelectedExistingReplacementThatCommitsThenThrowsReconcilesAsSuccess() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("existing.ply")
        try Data("previous destination".utf8).write(to: destination)
        let expected = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        var operations = UserSelectedPlyPublicationFileOperations.system()
        let replaceExisting = operations.replaceExisting
        operations.replaceExisting = { selected, candidate in
            _ = try replaceExisting(selected, candidate)
            throw CocoaError(.fileWriteUnknown)
        }

        let published = try publishUserSelected(
            source: source,
            destination: destination,
            fileOperations: operations
        )

        XCTAssertEqual(published, expected)
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
    }

    func testUserSelectedExistingReplacementIgnoresUnprovenReturnedURLVariants() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let unrelated = root.appendingPathComponent("unrelated.ply")
        let unrelatedBytes = Data("must remain unrelated".utf8)
        try unrelatedBytes.write(to: unrelated)

        for variant in 0..<3 {
            let destination = root.appendingPathComponent("existing-\(variant).ply")
            try Data("previous destination \(variant)".utf8).write(to: destination)
            var operations = UserSelectedPlyPublicationFileOperations.system()
            let replaceExisting = operations.replaceExisting
            operations.replaceExisting = { selected, candidate in
                _ = try replaceExisting(selected, candidate)
                switch variant {
                case 0:
                    return nil
                case 1:
                    return selected
                default:
                    return unrelated
                }
            }

            _ = try publishUserSelected(
                source: source,
                destination: destination,
                fileOperations: operations
            )

            XCTAssertEqual(
                try Data(contentsOf: destination),
                try Data(contentsOf: source)
            )
            XCTAssertEqual(try Data(contentsOf: unrelated), unrelatedBytes)
        }
    }

    func testUserSelectedPublicationAcceptsPreexistingIdenticalDestinationWhenCommitFails() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("chosen.ply")
        try Data(contentsOf: source).write(to: destination)
        let expected = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        let published = try publishUserSelected(
            source: source,
            destination: destination
        )

        XCTAssertEqual(published, expected)
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
    }

    func testUserSelectedPublicationAcceptsConcurrentIdenticalDestinationWhenAbsentCommitThrows() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("chosen.ply")
        let expected = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        var operations = UserSelectedPlyPublicationFileOperations.system()
        operations.cloneAbsent = { _, selected in
            try Data(contentsOf: source).write(to: selected)
            throw CocoaError(.fileWriteFileExists)
        }

        let published = try publishUserSelected(
            source: source,
            destination: destination,
            fileOperations: operations
        )

        XCTAssertEqual(published, expected)
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
    }

    func testUserSelectedDifferentExistingFileAndForeignCandidateNameRemainUntouched() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("chosen.ply")
        let original = Data("original destination".utf8)
        try original.write(to: destination)
        let foreignCandidate = Data("foreign candidate".utf8)
        let staging = root.appendingPathComponent("owned-staging", isDirectory: true)
        var operations = UserSelectedPlyPublicationFileOperations.system()
        operations.createReplacementDirectory = { _ in
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            return staging
        }
        operations.beforeCommit = {
            let candidate = try XCTUnwrap(
                FileManager.default.contentsOfDirectory(
                    at: staging,
                    includingPropertiesForKeys: nil
                ).first
            )
            let heldCandidate = root.appendingPathComponent("held-candidate.ply")
            try FileManager.default.moveItem(at: candidate, to: heldCandidate)
            try foreignCandidate.write(to: candidate)
        }

        XCTAssertThrowsError(
            try publishUserSelected(
                source: source,
                destination: destination,
                fileOperations: operations
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectArtifactError,
                .publicationFailed(destination.lastPathComponent)
            )
        }
        XCTAssertEqual(try Data(contentsOf: destination), original)
        XCTAssertTrue(
            try allRegularFileContents(below: root).contains(original),
            "A raced publication must retain the displaced original bytes."
        )
        XCTAssertTrue(
            try allRegularFileContents(below: root).contains(foreignCandidate),
            "Cleanup must not unlink a foreign replacement of the candidate name."
        )
    }

    func testUserSelectedAbsentPublicationUsesCandidateDescriptorAfterNameSubstitution() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        let foreignSource = root.appendingPathComponent("foreign-source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        try TestFileBuilder.writeMinimalPly(at: foreignSource, vertexCount: 1)
        let destination = root.appendingPathComponent("chosen.ply")
        let staging = root.appendingPathComponent("owned-staging", isDirectory: true)
        let heldCandidate = root.appendingPathComponent("held-candidate.ply")
        var substitutedName: URL?
        var operations = UserSelectedPlyPublicationFileOperations.system()
        operations.createReplacementDirectory = { _ in
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            return staging
        }
        operations.beforeCommit = {
            let candidate = try XCTUnwrap(
                FileManager.default.contentsOfDirectory(
                    at: staging,
                    includingPropertiesForKeys: nil
                ).first
            )
            substitutedName = candidate
            try FileManager.default.moveItem(at: candidate, to: heldCandidate)
            try Data(contentsOf: foreignSource).write(to: candidate)
        }

        _ = try publishUserSelected(
            source: source,
            destination: destination,
            fileOperations: operations
        )

        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
        XCTAssertEqual(
            try Data(contentsOf: try XCTUnwrap(substitutedName)),
            try Data(contentsOf: foreignSource)
        )
        XCTAssertEqual(try Data(contentsOf: heldCandidate), try Data(contentsOf: source))
    }

    func testUserSelectedCleanupRemovesOwnedCandidateAndDirectoryAfterSuccess() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("chosen.ply")
        let staging = root.appendingPathComponent("owned-staging", isDirectory: true)
        var operations = UserSelectedPlyPublicationFileOperations.system()
        operations.createReplacementDirectory = { _ in
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            return staging
        }
        _ = try publishUserSelected(
            source: source,
            destination: destination,
            fileOperations: operations
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
    }

    func testUserSelectedCleanupRemovesEmptyStagingAfterCandidateCreationFailure() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("chosen.ply")
        let staging = root.appendingPathComponent("read-only-staging", isDirectory: true)
        var operations = UserSelectedPlyPublicationFileOperations.system()
        operations.createReplacementDirectory = { _ in
            try FileManager.default.createDirectory(
                at: staging,
                withIntermediateDirectories: false
            )
            guard Darwin.chmod(staging.path, 0o500) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            return staging
        }

        XCTAssertThrowsError(
            try publishUserSelected(
                source: source,
                destination: destination,
                fileOperations: operations
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectArtifactError,
                .publicationFailed(destination.lastPathComponent)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testUserSelectedCleanupCannotTruncateCandidateMovedOntoReconciledDestination() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("chosen.ply")
        let staging = root.appendingPathComponent("owned-staging", isDirectory: true)
        var didExchange = false
        var operations = UserSelectedPlyPublicationFileOperations.system()
        operations.createReplacementDirectory = { _ in
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            return staging
        }
        operations.beforeStagingCleanup = { _ in
            let candidate = try XCTUnwrap(
                FileManager.default.contentsOfDirectory(
                    at: staging,
                    includingPropertiesForKeys: nil
                ).first
            )
            try self.exchange(candidate, destination)
            didExchange = true
        }

        _ = try publishUserSelected(
            source: source,
            destination: destination,
            fileOperations: operations
        )

        XCTAssertTrue(didExchange)
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
        let retained = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: staging,
                includingPropertiesForKeys: nil
            ).first
        )
        XCTAssertEqual(try Data(contentsOf: retained), try Data(contentsOf: source))
    }

    func testUserSelectedPublicationTreatsReplacementDirectoryFailureAsDestinationFailure() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("chosen.ply")
        var operations = UserSelectedPlyPublicationFileOperations.system()
        operations.createReplacementDirectory = { _ in
            throw CocoaError(.fileWriteNoPermission)
        }

        XCTAssertThrowsError(
            try publishUserSelected(
                source: source,
                destination: destination,
                fileOperations: operations
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectArtifactError,
                .publicationFailed(destination.lastPathComponent)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testUserSelectedPublicationReconcilesSuccessfulAbsentCloneThatThrows() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let expected = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        let destination = root.appendingPathComponent("chosen.ply")
        var operations = UserSelectedPlyPublicationFileOperations.system()
        let cloneAbsent = operations.cloneAbsent
        operations.cloneAbsent = { candidate, selected in
            try cloneAbsent(candidate, selected)
            throw CocoaError(.fileWriteUnknown)
        }

        let published = try publishUserSelected(
            source: source,
            destination: destination,
            fileOperations: operations
        )

        XCTAssertEqual(published, expected)
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
    }

    func testUserSelectedPublicationReportsFailedAbsentCloneWithoutCreatingDestination() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("chosen.ply")
        var operations = UserSelectedPlyPublicationFileOperations.system()
        operations.cloneAbsent = { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        }

        XCTAssertThrowsError(
            try publishUserSelected(
                source: source,
                destination: destination,
                fileOperations: operations
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectArtifactError,
                .publicationFailed(destination.lastPathComponent)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testUserSelectedPublicationPreservesForeignConcurrentCreation() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("chosen.ply")
        let foreign = Data("foreign destination".utf8)
        var operations = UserSelectedPlyPublicationFileOperations.system()
        operations.cloneAbsent = { _, selected in
            try foreign.write(to: selected)
            throw CocoaError(.fileWriteFileExists)
        }

        XCTAssertThrowsError(
            try publishUserSelected(
                source: source,
                destination: destination,
                fileOperations: operations
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectArtifactError,
                .publicationConflict(destination.lastPathComponent)
            )
        }
        XCTAssertEqual(try Data(contentsOf: destination), foreign)
    }

    func testUserSelectedPublicationPreservesUnchangedExistingFileWhenReplacementIsUnsafe() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("chosen.ply")
        let previous = Data("previous destination".utf8)
        try previous.write(to: destination)
        var operations = UserSelectedPlyPublicationFileOperations.system()
        operations.replaceExisting = { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        }

        XCTAssertThrowsError(
            try publishUserSelected(
                source: source,
                destination: destination,
                fileOperations: operations
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectArtifactError,
                .publicationFailed(destination.lastPathComponent)
            )
        }
        XCTAssertEqual(try Data(contentsOf: destination), previous)
    }

    func testUserSelectedExistingDestinationSubstitutionBeforeCommitPreservesForeignFileAsConflict() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("chosen.ply")
        let original = Data("original destination".utf8)
        try original.write(to: destination)
        let foreignHolder = root.appendingPathComponent("foreign-holder.ply")
        let foreign = Data("foreign concurrent destination".utf8)
        try foreign.write(to: foreignHolder)
        let staging = root.appendingPathComponent("owned-staging", isDirectory: true)
        var operations = UserSelectedPlyPublicationFileOperations.system()
        operations.createReplacementDirectory = { _ in
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            return staging
        }
        operations.beforeCommit = {
            try self.exchange(destination, foreignHolder)
        }

        XCTAssertThrowsError(
            try publishUserSelected(
                source: source,
                destination: destination,
                fileOperations: operations
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectArtifactError,
                .publicationConflict(destination.lastPathComponent)
            )
        }
        XCTAssertEqual(try Data(contentsOf: foreignHolder), original)
        XCTAssertTrue(
            try allRegularFileContents(below: root).contains(foreign),
            "The foreign destination inode must survive reconciliation and cleanup."
        )
    }

    func testUserSelectedSnapshotIdentityDisagreementIsAConflict() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("chosen.ply")
        let destinationBytes = Data("original destination".utf8)
        try destinationBytes.write(to: destination)
        let other = root.appendingPathComponent("other.ply")
        let otherBytes = Data("different inode".utf8)
        try otherBytes.write(to: other)
        var operations = UserSelectedPlyPublicationFileOperations.system()
        let exactOpen = operations.openExactFile
        operations.openExactFile = { url, flags in
            exactOpen(url == destination ? other : url, flags)
        }

        XCTAssertThrowsError(
            try publishUserSelected(
                source: source,
                destination: destination,
                fileOperations: operations
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectArtifactError,
                .publicationConflict(destination.lastPathComponent)
            )
        }
        XCTAssertEqual(try Data(contentsOf: destination), destinationBytes)
        XCTAssertEqual(try Data(contentsOf: other), otherBytes)
    }

    func testUserSelectedReconciliationOpensOnlyTheExactSelectedPath() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("chosen.ply")
        var opened: [URL] = []
        var operations = UserSelectedPlyPublicationFileOperations.system()
        let exactOpen = operations.openExactFile
        operations.openExactFile = { url, flags in
            opened.append(url)
            return exactOpen(url, flags)
        }

        _ = try publishUserSelected(
            source: source,
            destination: destination,
            fileOperations: operations
        )

        XCTAssertEqual(opened, [destination, destination, destination])
        XCTAssertFalse(opened.contains(destination.deletingLastPathComponent()))
    }

    func testUserSelectedCandidateIsExclusivePrivateAndSupportsShortReadsAndWrites() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("chosen.ply")
        var candidateMode: mode_t?
        var operations = UserSelectedPlyPublicationFileOperations.system()
        let cloneAbsent = operations.cloneAbsent
        operations.cloneAbsent = { candidate, selected in
            var metadata = stat()
            XCTAssertEqual(fstat(candidate, &metadata), 0)
            candidateMode = metadata.st_mode & 0o7777
            try cloneAbsent(candidate, selected)
        }
        var calls = PlyPublicationSystemCalls.system()
        calls.readAt = { descriptor, bytes, count, offset in
            Darwin.pread(descriptor, bytes, max(1, count / 2), offset)
        }
        calls.write = { descriptor, bytes, count in
            Darwin.write(descriptor, bytes, max(1, count / 2))
        }

        _ = try publishUserSelected(
            source: source,
            destination: destination,
            systemCalls: calls,
            fileOperations: operations
        )

        XCTAssertEqual(candidateMode, mode_t(S_IRUSR | S_IWUSR))
        var publishedMetadata = stat()
        XCTAssertEqual(lstat(destination.path, &publishedMetadata), 0)
        XCTAssertEqual(
            publishedMetadata.st_mode & 0o7777,
            mode_t(S_IRUSR | S_IWUSR)
        )
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
    }

    func testUserSelectedZeroLengthWriteAndFsyncFailureDoNotPublish() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)

        for failure in ["write", "fsync"] {
            let destination = root.appendingPathComponent("\(failure).ply")
            var calls = PlyPublicationSystemCalls.system()
            if failure == "write" {
                calls.write = { _, _, _ in 0 }
            } else {
                calls.synchronize = { _ in
                    errno = EIO
                    return -1
                }
            }

            XCTAssertThrowsError(
                try publishUserSelected(
                    source: source,
                    destination: destination,
                    systemCalls: calls
                )
            ) { error in
                XCTAssertEqual(
                    error as? ProjectArtifactError,
                    .publicationFailed(destination.lastPathComponent)
                )
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        }
    }

    func testUserSelectedPublicationRejectsSourceMutationAfterStreaming() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("chosen.ply")
        let mutationOffset = try firstVertexXOffset(in: source)
        let mutationDescriptor = Darwin.open(source.path, O_WRONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(mutationDescriptor, 0)
        defer { Darwin.close(mutationDescriptor) }
        var mutated = false
        var calls = PlyPublicationSystemCalls.system()
        let write = calls.write
        calls.write = { descriptor, bytes, count in
            let result = write(descriptor, bytes, count)
            if result > 0, !mutated {
                mutated = true
                var byte = UInt8(ascii: "1")
                _ = Darwin.pwrite(mutationDescriptor, &byte, 1, off_t(mutationOffset))
            }
            return result
        }

        XCTAssertThrowsError(
            try publishUserSelected(
                source: source,
                destination: destination,
                systemCalls: calls
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectArtifactError,
                .invalidOutput(source.lastPathComponent)
            )
        }
        XCTAssertTrue(mutated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testUserSelectedExistingDestinationForeignOrMissingAfterFailureIsNeverRepaired() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let foreign = Data("foreign destination".utf8)

        for action in ["foreign", "missing"] {
            let destination = root.appendingPathComponent("\(action).ply")
            try Data("previous destination".utf8).write(to: destination)
            var operations = UserSelectedPlyPublicationFileOperations.system()
            operations.beforeCommit = {
                if action == "foreign" {
                    try foreign.write(to: destination)
                } else {
                    try FileManager.default.removeItem(at: destination)
                }
            }

            XCTAssertThrowsError(
                try publishUserSelected(
                    source: source,
                    destination: destination,
                    fileOperations: operations
                )
            ) { error in
                XCTAssertEqual(
                    error as? ProjectArtifactError,
                    .publicationConflict(destination.lastPathComponent)
                )
            }
            if action == "foreign" {
                XCTAssertEqual(try Data(contentsOf: destination), foreign)
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            }
        }
    }

    func testUserSelectedUnstableDestinationDuringReconciliationIsPreservedAsConflict() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("chosen.ply")
        let mutationOffset = try firstVertexXOffset(in: source)
        var publicationMoved = false
        var mutated = false
        var operations = UserSelectedPlyPublicationFileOperations.system()
        let cloneAbsent = operations.cloneAbsent
        operations.cloneAbsent = { candidate, selected in
            try cloneAbsent(candidate, selected)
            publicationMoved = true
        }
        var calls = PlyPublicationSystemCalls.system()
        let readAt = calls.readAt
        calls.readAt = { descriptor, bytes, count, offset in
            let result = readAt(descriptor, bytes, count, offset)
            if result > 0, publicationMoved, !mutated {
                mutated = true
                let writer = Darwin.open(destination.path, O_WRONLY | O_CLOEXEC)
                if writer >= 0 {
                    var byte = UInt8(ascii: "1")
                    _ = Darwin.pwrite(writer, &byte, 1, off_t(mutationOffset))
                    Darwin.close(writer)
                }
            }
            return result
        }

        XCTAssertThrowsError(
            try publishUserSelected(
                source: source,
                destination: destination,
                systemCalls: calls,
                fileOperations: operations
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectArtifactError,
                .publicationConflict(destination.lastPathComponent)
            )
        }
        XCTAssertTrue(mutated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertNotEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
    }

    func testUserSelectedPublicationRejectsCandidateMutationAfterFsync() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("chosen.ply")
        let mutationOffset = try firstVertexXOffset(in: source)
        var mutated = false
        var calls = PlyPublicationSystemCalls.system()
        calls.synchronize = { descriptor in
            let result = Darwin.fsync(descriptor)
            if result == 0, !mutated {
                mutated = true
                var byte = UInt8(ascii: "1")
                _ = Darwin.pwrite(descriptor, &byte, 1, off_t(mutationOffset))
            }
            return result
        }

        XCTAssertThrowsError(
            try publishUserSelected(
                source: source,
                destination: destination,
                systemCalls: calls
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectArtifactError,
                .publicationFailed(destination.lastPathComponent)
            )
        }
        XCTAssertTrue(mutated)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testUserSelectedCancellationImmediatelyBeforeCommitLeavesDestinationAbsent() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("chosen.ply")
        let cancellation = UserSelectedExportCancellationState()
        var moveWasCalled = false
        var operations = UserSelectedPlyPublicationFileOperations.system()
        operations.beforeCommit = { cancellation.cancel() }
        operations.cloneAbsent = { _, _ in moveWasCalled = true }

        XCTAssertThrowsError(
            try publishUserSelected(
                source: source,
                destination: destination,
                fileOperations: operations,
                shouldCancel: { cancellation.isCancelled }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(moveWasCalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testUserSelectedCancellationAfterAbsentCommitStillReconcilesAsSuccess() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("chosen.ply")
        let cancellation = UserSelectedExportCancellationState()
        var operations = UserSelectedPlyPublicationFileOperations.system()
        let cloneAbsent = operations.cloneAbsent
        operations.cloneAbsent = { candidate, selected in
            try cloneAbsent(candidate, selected)
            cancellation.cancel()
        }

        let published = try publishUserSelected(
            source: source,
            destination: destination,
            fileOperations: operations,
            shouldCancel: { cancellation.isCancelled }
        )

        XCTAssertTrue(cancellation.isCancelled)
        XCTAssertEqual(
            published,
            try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        )
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
    }

    func testUserSelectedCancellationBeforeExistingCommitPreservesOriginal() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("chosen.ply")
        let original = Data("previous destination".utf8)
        try original.write(to: destination)
        let cancellation = UserSelectedExportCancellationState()
        var replaceWasCalled = false
        var operations = UserSelectedPlyPublicationFileOperations.system()
        operations.beforeCommit = { cancellation.cancel() }
        operations.replaceExisting = { _, _ in
            replaceWasCalled = true
            return nil
        }

        XCTAssertThrowsError(
            try publishUserSelected(
                source: source,
                destination: destination,
                fileOperations: operations,
                shouldCancel: { cancellation.isCancelled }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(replaceWasCalled)
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testUserSelectedPublicationRejectsDirectoryTargetWithoutChangingIt() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let directory = root.appendingPathComponent("directory-target", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try publishUserSelected(source: source, destination: directory)
        ) { error in
            XCTAssertEqual(
                error as? ProjectArtifactError,
                .publicationFailed(directory.lastPathComponent)
            )
        }
        var isDirectory = ObjCBool(false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testUserSelectedPublicationRejectsSymlinkTargetWithoutChangingIt() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let symlinkTarget = root.appendingPathComponent("symlink-target.ply")
        let symlink = root.appendingPathComponent("symlink.ply")
        let targetBytes = Data("preserve target".utf8)
        try targetBytes.write(to: symlinkTarget)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: symlinkTarget)

        XCTAssertThrowsError(
            try publishUserSelected(source: source, destination: symlink)
        ) { error in
            XCTAssertEqual(
                error as? ProjectArtifactError,
                .publicationFailed(symlink.lastPathComponent)
            )
        }
        XCTAssertEqual(try Data(contentsOf: symlinkTarget), targetBytes)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path), symlinkTarget.path)
    }

    func testUserSelectedPublicationRejectsFIFOTargetWithoutChangingIt() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let fifo = root.appendingPathComponent("chosen.ply")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, mode_t(S_IRUSR | S_IWUSR)), 0)

        XCTAssertThrowsError(
            try publishUserSelected(source: source, destination: fifo)
        ) { error in
            XCTAssertEqual(
                error as? ProjectArtifactError,
                .publicationFailed(fifo.lastPathComponent)
            )
        }
        var metadata = stat()
        XCTAssertEqual(lstat(fifo.path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & S_IFMT, S_IFIFO)
    }

    func testUserSelectedPublicationRejectsMultiplyLinkedTargetWithoutChangingEitherLink() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let original = root.appendingPathComponent("original.ply")
        let destination = root.appendingPathComponent("chosen.ply")
        let previous = Data("multiply linked destination".utf8)
        try previous.write(to: original)
        try FileManager.default.linkItem(at: original, to: destination)

        XCTAssertThrowsError(
            try publishUserSelected(source: source, destination: destination)
        ) { error in
            XCTAssertEqual(
                error as? ProjectArtifactError,
                .publicationFailed(destination.lastPathComponent)
            )
        }
        XCTAssertEqual(try Data(contentsOf: original), previous)
        XCTAssertEqual(try Data(contentsOf: destination), previous)
        var metadata = stat()
        XCTAssertEqual(lstat(destination.path, &metadata), 0)
        XCTAssertEqual(metadata.st_nlink, 2)
    }

    func testUserSelectedCleanupFailureDoesNotOverrideReconciledSuccess() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let expected = try ProjectArtifactValidator.validatedPlyEvidence(at: source)
        let destination = root.appendingPathComponent("chosen.ply")
        let staging = root.appendingPathComponent("owned-staging", isDirectory: true)
        var cleanupWasCalled = false
        var operations = UserSelectedPlyPublicationFileOperations.system()
        operations.createReplacementDirectory = { _ in
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            return staging
        }
        operations.cleanupStaging = { context in
            XCTAssertEqual(context.stagingURL, staging)
            cleanupWasCalled = true
            throw CocoaError(.fileWriteNoPermission)
        }

        let published = try publishUserSelected(
            source: source,
            destination: destination,
            fileOperations: operations
        )

        XCTAssertEqual(published, expected)
        XCTAssertTrue(cleanupWasCalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
    }

    func testUserSelectedCleanupPreservesForeignDirectorySwappedOverOwnedStaging() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.ply")
        try TestFileBuilder.writeMinimalPly(at: source, vertexCount: 2)
        let destination = root.appendingPathComponent("chosen.ply")
        let staging = root.appendingPathComponent("owned-staging", isDirectory: true)
        let foreign = root.appendingPathComponent("foreign-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        let marker = foreign.appendingPathComponent("foreign-marker")
        let markerBytes = Data("must survive cleanup".utf8)
        try markerBytes.write(to: marker)
        var operations = UserSelectedPlyPublicationFileOperations.system()
        operations.createReplacementDirectory = { _ in
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
            return staging
        }
        operations.beforeStagingCleanup = { selectedStaging in
            XCTAssertEqual(selectedStaging, staging)
            try self.exchange(staging, foreign)
        }

        _ = try publishUserSelected(
            source: source,
            destination: destination,
            fileOperations: operations
        )

        XCTAssertEqual(
            try Data(contentsOf: staging.appendingPathComponent("foreign-marker")),
            markerBytes
        )
        var stagingMetadata = stat()
        XCTAssertEqual(lstat(staging.path, &stagingMetadata), 0)
        XCTAssertEqual(stagingMetadata.st_mode & S_IFMT, S_IFDIR)
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
    }

    private func publishUserSelected(
        source: URL,
        destination: URL,
        systemCalls: PlyPublicationSystemCalls = .system(),
        fileOperations: UserSelectedPlyPublicationFileOperations = .system(),
        shouldCancel: @escaping @Sendable () -> Bool = { false }
    ) throws -> ValidatedPlyArtifactEvidence {
        try ProjectArtifactValidator.publishValidatedPly(
            from: source,
            to: destination,
            expected: nil,
            destinationKind: .userSelected,
            systemCalls: systemCalls,
            fileOperations: fileOperations,
            shouldCancel: shouldCancel
        )
    }

    private func firstVertexXOffset(in url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let marker = Data("end_header\n".utf8)
        let header = try XCTUnwrap(data.range(of: marker))
        return header.upperBound
    }

    private func exchange(_ first: URL, _ second: URL) throws {
        let firstParentDescriptor = Darwin.open(
            first.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard firstParentDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(firstParentDescriptor) }
        let secondParentDescriptor = Darwin.open(
            second.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        guard secondParentDescriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { Darwin.close(secondParentDescriptor) }
        let result = first.lastPathComponent.withCString { firstPath in
            second.lastPathComponent.withCString { secondPath in
                Darwin.renameatx_np(
                    firstParentDescriptor,
                    firstPath,
                    secondParentDescriptor,
                    secondPath,
                    UInt32(RENAME_SWAP | RENAME_NOFOLLOW_ANY)
                )
            }
        }
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private func allRegularFileContents(below root: URL) throws -> [Data] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }
        var contents: [Data] = []
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                contents.append(try Data(contentsOf: url))
            }
        }
        return contents
    }
}

private final class UserSelectedExportCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}
