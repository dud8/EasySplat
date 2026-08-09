import Darwin
import XCTest
@testable import EasySplatCore

final class ProjectMetadataBoundStoreTests: XCTestCase {
    func testBoundLoadRejectsHardlinkedProjectMetadata() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let metadataURL = root.appendingPathComponent("project.json")
        let linkedURL = root.appendingPathComponent("project-copy.json")
        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Bound", input: .video(files: [])),
            to: metadataURL
        )
        try FileManager.default.linkItem(at: metadataURL, to: linkedURL)

        let descriptor = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }

        XCTAssertThrowsError(
            try ProjectMetadataStore.load(
                fromProjectRootDescriptor: descriptor
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectMetadataBoundError,
                .unsafeMetadata
            )
        }
    }

    func testBoundSaveNeverWritesNamedReplacementAfterProjectRootMoves() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let projectRoot = parent.appendingPathComponent(
            "Original.easysplatproj",
            isDirectory: true
        )
        let movedRoot = parent.appendingPathComponent(
            "Moved.easysplatproj",
            isDirectory: true
        )
        let foreignRoot = parent.appendingPathComponent(
            "Foreign.easysplatproj",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectRoot,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: foreignRoot,
            withIntermediateDirectories: false
        )
        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Original", input: .video(files: [])),
            to: ProjectPaths(root: projectRoot).metadataURL
        )
        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Foreign", input: .video(files: [])),
            to: ProjectPaths(root: foreignRoot).metadataURL
        )
        let foreignBytes = try Data(
            contentsOf: ProjectPaths(root: foreignRoot).metadataURL
        )
        let replacementURL = ProjectPaths(root: projectRoot).metadataURL

        let descriptor = Darwin.open(
            projectRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }

        var operations = ProjectMetadataBoundOperations.system()
        operations.didReachCheckpoint = { checkpoint, _, _ in
            guard checkpoint == .readyToCommit else { return }
            try FileManager.default.moveItem(at: projectRoot, to: movedRoot)
            try FileManager.default.createDirectory(
                at: projectRoot,
                withIntermediateDirectories: false
            )
            try foreignBytes.write(to: replacementURL, options: .withoutOverwriting)
        }

        XCTAssertThrowsError(
            try ProjectMetadataStore.save(
                ProjectMetadata(title: "Updated", input: .video(files: [])),
                toProjectRootDescriptor: descriptor,
                operations: operations
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectMetadataBoundError,
                .unsafeProjectRoot
            )
        }

        XCTAssertEqual(try Data(contentsOf: replacementURL), foreignBytes)
        XCTAssertEqual(
            try ProjectMetadataStore.load(
                from: ProjectPaths(root: movedRoot).metadataURL
            ).title,
            "Original"
        )
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: movedRoot.path)
                .sorted(),
            ["project.json"]
        )
    }

    func testBoundSavePreservesProjectMetadataReplacedAtCommit() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Original", input: .video(files: [])),
            to: paths.metadataURL
        )

        let foreignRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: foreignRoot) }
        let foreignURL = ProjectPaths(root: foreignRoot).metadataURL
        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Foreign", input: .video(files: [])),
            to: foreignURL
        )
        let foreignBytes = try Data(contentsOf: foreignURL)
        let stagedForeignLeaf = "foreign-project.json"
        try foreignBytes.write(
            to: root.appendingPathComponent(stagedForeignLeaf),
            options: .withoutOverwriting
        )

        let descriptor = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }

        let injected = LockedFlag()
        let systemExchange = ProjectMetadataBoundOperations.system().exchange
        var operations = ProjectMetadataBoundOperations.system()
        operations.exchange = { rootDescriptor, source, destination in
            if injected.take() {
                let retiredLeaf = "retired-original.json"
                guard renameAt(
                    rootDescriptor,
                    "project.json",
                    retiredLeaf
                ) == 0,
                renameAt(
                    rootDescriptor,
                    stagedForeignLeaf,
                    "project.json"
                ) == 0 else {
                    return -1
                }
            }
            return systemExchange(rootDescriptor, source, destination)
        }

        XCTAssertThrowsError(
            try ProjectMetadataStore.save(
                ProjectMetadata(title: "Updated", input: .video(files: [])),
                toProjectRootDescriptor: descriptor,
                operations: operations
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectMetadataBoundError,
                .metadataConflict
            )
        }

        XCTAssertEqual(try Data(contentsOf: paths.metadataURL), foreignBytes)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.path)
                .contains { $0.hasPrefix(".project-metadata-") }
        )
    }

    func testBoundSaveRejectsValidatedCandidateReplacementBeforeCommit() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Original", input: .video(files: [])),
            to: paths.metadataURL
        )
        let originalBytes = try Data(contentsOf: paths.metadataURL)

        let foreignRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: foreignRoot) }
        let foreignURL = ProjectPaths(root: foreignRoot).metadataURL
        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Foreign", input: .video(files: [])),
            to: foreignURL
        )
        let foreignBytes = try Data(contentsOf: foreignURL)
        let foreignLeaf = "foreign-candidate.json"
        try foreignBytes.write(
            to: root.appendingPathComponent(foreignLeaf),
            options: .withoutOverwriting
        )

        let descriptor = try openProjectRoot(root)
        defer { Darwin.close(descriptor) }
        let candidateLeaf = LockedStringBox()
        var operations = ProjectMetadataBoundOperations.system()
        operations.didReachCheckpoint = { checkpoint, rootDescriptor, candidate in
            guard checkpoint == .candidateValidated,
                  let candidate else { return }
            candidateLeaf.set(candidate)
            guard renameAt(
                rootDescriptor,
                candidate,
                "validated-candidate.json"
            ) == 0,
            renameAt(rootDescriptor, foreignLeaf, candidate) == 0 else {
                throw posixError()
            }
        }

        XCTAssertThrowsError(
            try ProjectMetadataStore.save(
                ProjectMetadata(title: "Updated", input: .video(files: [])),
                toProjectRootDescriptor: descriptor,
                operations: operations
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectMetadataBoundError,
                .metadataConflict
            )
        }

        XCTAssertEqual(try Data(contentsOf: paths.metadataURL), originalBytes)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent(candidateLeaf.value)),
            foreignBytes
        )
        XCTAssertEqual(
            try ProjectMetadataStore.load(
                from: root.appendingPathComponent("validated-candidate.json")
            ).title,
            "Updated"
        )
    }

    func testBoundSaveRestoresPriorMetadataWhenCandidateChangesInsideExchange() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Original", input: .video(files: [])),
            to: paths.metadataURL
        )
        let originalBytes = try Data(contentsOf: paths.metadataURL)

        let foreignRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: foreignRoot) }
        let foreignURL = ProjectPaths(root: foreignRoot).metadataURL
        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Foreign", input: .video(files: [])),
            to: foreignURL
        )
        let foreignBytes = try Data(contentsOf: foreignURL)
        let foreignLeaf = "foreign-candidate.json"
        try foreignBytes.write(
            to: root.appendingPathComponent(foreignLeaf),
            options: .withoutOverwriting
        )

        let descriptor = try openProjectRoot(root)
        defer { Darwin.close(descriptor) }
        let candidateLeaf = LockedStringBox()
        let injected = LockedFlag()
        let systemExchange = ProjectMetadataBoundOperations.system().exchange
        var operations = ProjectMetadataBoundOperations.system()
        operations.exchange = { rootDescriptor, source, destination in
            candidateLeaf.set(source)
            if injected.take() {
                guard renameAt(
                    rootDescriptor,
                    source,
                    "validated-candidate.json"
                ) == 0,
                renameAt(rootDescriptor, foreignLeaf, source) == 0 else {
                    return -1
                }
            }
            return systemExchange(rootDescriptor, source, destination)
        }

        XCTAssertThrowsError(
            try ProjectMetadataStore.save(
                ProjectMetadata(title: "Updated", input: .video(files: [])),
                toProjectRootDescriptor: descriptor,
                operations: operations
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectMetadataBoundError,
                .metadataConflict
            )
        }

        XCTAssertEqual(try Data(contentsOf: paths.metadataURL), originalBytes)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent(candidateLeaf.value)),
            foreignBytes
        )
        XCTAssertEqual(
            try ProjectMetadataStore.load(
                from: root.appendingPathComponent("validated-candidate.json")
            ).title,
            "Updated"
        )
    }

    func testBoundInitialSavePreservesForeignCanonicalWhenCandidateIsReplacedDuringInstall() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        let foreignRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: foreignRoot) }
        let foreignURL = ProjectPaths(root: foreignRoot).metadataURL
        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Foreign", input: .video(files: [])),
            to: foreignURL
        )
        let foreignBytes = try Data(contentsOf: foreignURL)
        let foreignLeaf = "foreign-candidate.json"
        try foreignBytes.write(
            to: root.appendingPathComponent(foreignLeaf),
            options: .withoutOverwriting
        )

        let descriptor = try openProjectRoot(root)
        defer { Darwin.close(descriptor) }
        let candidateLeaf = LockedStringBox()
        let injected = LockedFlag()
        let systemRenameExclusive = ProjectMetadataBoundOperations.system()
            .renameExclusive
        var operations = ProjectMetadataBoundOperations.system()
        operations.renameExclusive = { rootDescriptor, source, destination in
            candidateLeaf.set(source)
            if injected.take() {
                guard renameAt(
                    rootDescriptor,
                    source,
                    "validated-candidate.json"
                ) == 0,
                renameAt(rootDescriptor, foreignLeaf, source) == 0 else {
                    return -1
                }
            }
            return systemRenameExclusive(rootDescriptor, source, destination)
        }

        XCTAssertThrowsError(
            try ProjectMetadataStore.save(
                ProjectMetadata(title: "Initial", input: .video(files: [])),
                toProjectRootDescriptor: descriptor,
                operations: operations
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectMetadataBoundError,
                .metadataConflict
            )
        }

        XCTAssertEqual(
            try Data(contentsOf: paths.metadataURL),
            foreignBytes
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(candidateLeaf.value).path
            )
        )
        XCTAssertEqual(
            try ProjectMetadataStore.load(
                from: root.appendingPathComponent("validated-candidate.json")
            ).title,
            "Initial"
        )
    }

    func testBoundPipelineSavePreservesLiveUserEditableFields() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        let current = ProjectMetadata(
            title: "Live title",
            input: .video(files: []),
            viewerPreferences: ViewerPreferences(isUprightFlipActive: true),
            state: PipelineState(stage: .importInput, lastError: nil),
            notes: "Live notes"
        )
        try ProjectMetadataStore.save(current, to: paths.metadataURL)
        var stalePipelineWrite = current
        stalePipelineWrite.title = "Stale title"
        stalePipelineWrite.notes = "Stale notes"
        stalePipelineWrite.viewerPreferences = ViewerPreferences(
            isUprightFlipActive: false
        )
        stalePipelineWrite.state = PipelineState(
            stage: .sfmFeatures,
            lastError: nil
        )

        let descriptor = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }

        try ProjectMetadataStore.savePreservingUserEditableFields(
            stalePipelineWrite,
            toProjectRootDescriptor: descriptor
        )

        let loaded = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(loaded.title, "Live title")
        XCTAssertEqual(loaded.notes, "Live notes")
        XCTAssertTrue(loaded.viewerPreferences.isUprightFlipActive)
        XCTAssertEqual(loaded.state.stage, .sfmFeatures)
    }

    func testBoundUpdateDoesNotOverwriteReplacementCreatedDuringMutation() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Original",
                input: .video(files: []),
                notes: "Original note"
            ),
            to: paths.metadataURL
        )

        let foreignRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: foreignRoot) }
        let foreignURL = ProjectPaths(root: foreignRoot).metadataURL
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Foreign",
                input: .video(files: []),
                notes: "Foreign note"
            ),
            to: foreignURL
        )
        let foreignBytes = try Data(contentsOf: foreignURL)

        let descriptor = Darwin.open(
            root.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }

        XCTAssertThrowsError(
            try ProjectMetadataStore.update(
                atProjectRootDescriptor: descriptor
            ) { metadata in
                metadata.notes = "Local mutation"
                try foreignBytes.write(to: paths.metadataURL, options: .atomic)
            }
        ) { error in
            XCTAssertEqual(
                error as? ProjectMetadataBoundError,
                .metadataConflict
            )
        }
        XCTAssertEqual(try Data(contentsOf: paths.metadataURL), foreignBytes)
    }

    func testBoundUpdateCallbackCanReenterAliasedStoreWithoutOverwritingNestedWrite() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Original",
                input: .video(files: []),
                notes: "Original note"
            ),
            to: paths.metadataURL
        )
        let descriptor = try openProjectRoot(root)
        defer { Darwin.close(descriptor) }
        let finished = DispatchSemaphore(value: 0)
        let errors = LockedErrorBox()

        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                _ = try ProjectMetadataStore.update(
                    atProjectRootDescriptor: descriptor
                ) { metadata in
                    _ = try ProjectMetadataStore.update(at: paths.metadataURL) {
                        $0.notes = "Nested write"
                    }
                    metadata.title = "Stale outer write"
                }
                errors.append(ProjectMetadataBoundError.metadataChanged)
            } catch {
                errors.append(error)
            }
        }

        XCTAssertEqual(
            finished.wait(timeout: .now() + 2),
            .success,
            "A metadata callback must not deadlock when an aliased store reenters."
        )
        XCTAssertEqual(errors.values.count, 1)
        XCTAssertEqual(
            errors.values.first as? ProjectMetadataBoundError,
            .metadataConflict
        )
        let loaded = try ProjectMetadataStore.load(from: paths.metadataURL)
        XCTAssertEqual(loaded.title, "Original")
        XCTAssertEqual(loaded.notes, "Nested write")
    }

    func testURLAndDescriptorAliasesShareOneInProcessLock() throws {
        let leaf = "easysplat-metadata-lock-\(UUID().uuidString)"
        let literalRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent(leaf, isDirectory: true)
        let canonicalRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(leaf, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: canonicalRoot) }
        try FileManager.default.createDirectory(
            at: literalRoot,
            withIntermediateDirectories: false
        )
        let metadataURL = ProjectPaths(root: literalRoot).metadataURL
        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Alias", input: .video(files: [])),
            to: metadataURL
        )

        let descriptor = Darwin.open(
            canonicalRoot.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }

        let firstEntered = DispatchSemaphore(value: 0)
        let releaseFirst = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        let errors = LockedErrorBox()

        DispatchQueue.global().async {
            defer { firstFinished.signal() }
            do {
                _ = try ProjectMetadataStore.update(at: metadataURL) { metadata in
                    metadata.notes = "First"
                    firstEntered.signal()
                    releaseFirst.wait()
                }
            } catch {
                errors.append(error)
            }
        }
        XCTAssertEqual(firstEntered.wait(timeout: .now() + 2), .success)

        DispatchQueue.global().async {
            secondStarted.signal()
            defer { secondFinished.signal() }
            do {
                _ = try ProjectMetadataStore.update(
                    atProjectRootDescriptor: descriptor
                ) { metadata in
                    secondEntered.signal()
                    metadata.notes = "Second"
                }
            } catch {
                errors.append(error)
            }
        }
        XCTAssertEqual(secondStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(
            secondEntered.wait(timeout: .now() + 0.1),
            .timedOut,
            "Path and descriptor aliases must serialize before either mutation runs."
        )

        releaseFirst.signal()
        XCTAssertEqual(firstFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondFinished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(errors.values.isEmpty, "Unexpected errors: \(errors.values)")
        XCTAssertEqual(
            try ProjectMetadataStore.load(from: metadataURL).notes,
            "Second"
        )
    }

    func testURLUpdateDoesNotReopenReplacementAfterChoosingRootLock() throws {
        let parent = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let projectRoot = parent.appendingPathComponent(
            "Project.easysplatproj",
            isDirectory: true
        )
        let parkedRoot = parent.appendingPathComponent(
            "Parked.easysplatproj",
            isDirectory: true
        )
        let replacementRoot = parent.appendingPathComponent(
            "Replacement.easysplatproj",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectRoot,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: replacementRoot,
            withIntermediateDirectories: false
        )
        let metadataURL = ProjectPaths(root: projectRoot).metadataURL
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Original",
                input: .video(files: []),
                notes: "Original note"
            ),
            to: metadataURL
        )
        try ProjectMetadataStore.save(
            ProjectMetadata(
                title: "Replacement",
                input: .video(files: []),
                notes: "Replacement note"
            ),
            to: ProjectPaths(root: replacementRoot).metadataURL
        )

        let mutations = LockedCounter()
        let injected = LockedFlag()
        var operations = ProjectMetadataBoundOperations.system()
        operations.didReachCheckpoint = { checkpoint, _, _ in
            guard checkpoint == .rootBound, injected.take() else { return }
            try FileManager.default.moveItem(at: projectRoot, to: parkedRoot)
            try FileManager.default.moveItem(
                at: replacementRoot,
                to: projectRoot
            )
        }

        XCTAssertThrowsError(
            try ProjectMetadataStore.update(
                at: metadataURL,
                operations: operations
            ) { metadata in
                _ = mutations.increment()
                metadata.notes = "Wrong root"
            }
        ) { error in
            XCTAssertEqual(
                error as? ProjectMetadataBoundError,
                .unsafeProjectRoot
            )
        }

        XCTAssertEqual(mutations.value, 0)
        XCTAssertEqual(
            try ProjectMetadataStore.load(
                from: ProjectPaths(root: parkedRoot).metadataURL
            ).notes,
            "Original note"
        )
        XCTAssertEqual(
            try ProjectMetadataStore.load(from: metadataURL).notes,
            "Replacement note"
        )
    }

    func testBoundSaveRetriesInterruptedWrites() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = try openProjectRoot(root)
        defer { Darwin.close(descriptor) }
        let attempts = LockedCounter()
        let systemWrite = ProjectMetadataBoundOperations.system().write
        var operations = ProjectMetadataBoundOperations.system()
        operations.write = { file, bytes, count in
            if attempts.increment() == 1 {
                errno = EINTR
                return -1
            }
            return systemWrite(file, bytes, count)
        }

        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Interrupted", input: .video(files: [])),
            toProjectRootDescriptor: descriptor,
            operations: operations
        )

        XCTAssertGreaterThan(attempts.value, 1)
        XCTAssertEqual(
            try ProjectMetadataStore.load(
                from: ProjectPaths(root: root).metadataURL
            ).title,
            "Interrupted"
        )
    }

    func testBoundSaveCompletesShortWrites() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = try openProjectRoot(root)
        defer { Darwin.close(descriptor) }
        let attempts = LockedCounter()
        let systemWrite = ProjectMetadataBoundOperations.system().write
        var operations = ProjectMetadataBoundOperations.system()
        operations.write = { file, bytes, count in
            _ = attempts.increment()
            return systemWrite(file, bytes, max(1, count / 3))
        }

        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Short writes", input: .video(files: [])),
            toProjectRootDescriptor: descriptor,
            operations: operations
        )

        XCTAssertGreaterThan(attempts.value, 1)
        XCTAssertEqual(
            try ProjectMetadataStore.load(
                from: ProjectPaths(root: root).metadataURL
            ).title,
            "Short writes"
        )
    }

    func testBoundSaveCleansPartiallyWrittenCandidateAfterWriteFailure() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let descriptor = try openProjectRoot(root)
        defer { Darwin.close(descriptor) }
        let attempts = LockedCounter()
        let systemWrite = ProjectMetadataBoundOperations.system().write
        var operations = ProjectMetadataBoundOperations.system()
        operations.write = { file, bytes, count in
            if attempts.increment() == 1 {
                return systemWrite(file, bytes, min(64, count))
            }
            errno = ENOSPC
            return -1
        }

        XCTAssertThrowsError(
            try ProjectMetadataStore.save(
                ProjectMetadata(title: "Partial", input: .video(files: [])),
                toProjectRootDescriptor: descriptor,
                operations: operations
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectMetadataBoundError,
                .persistence(
                    operation: "write the metadata candidate",
                    code: ENOSPC
                )
            )
        }

        XCTAssertGreaterThan(attempts.value, 1)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ProjectPaths(root: root).metadataURL.path
            )
        )
        XCTAssertTrue(try metadataCandidateLeaves(in: root).isEmpty)
    }

    func testBoundSavePreservesForeignReplacementDuringInitialRollback() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        let foreignRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: foreignRoot) }
        let foreignURL = ProjectPaths(root: foreignRoot).metadataURL
        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Foreign", input: .video(files: [])),
            to: foreignURL
        )
        let foreignBytes = try Data(contentsOf: foreignURL)
        let foreignLeaf = "foreign-project.json"
        try foreignBytes.write(
            to: root.appendingPathComponent(foreignLeaf),
            options: .withoutOverwriting
        )

        let descriptor = try openProjectRoot(root)
        defer { Darwin.close(descriptor) }
        let injected = LockedFlag()
        let systemSynchronizeDirectory = ProjectMetadataBoundOperations.system()
            .synchronizeDirectory
        var operations = ProjectMetadataBoundOperations.system()
        operations.synchronizeDirectory = { rootDescriptor in
            guard injected.take() else {
                return systemSynchronizeDirectory(rootDescriptor)
            }
            guard renameAt(
                rootDescriptor,
                "project.json",
                "transaction-installed.json"
            ) == 0,
            renameAt(rootDescriptor, foreignLeaf, "project.json") == 0 else {
                return -1
            }
            errno = ENOSPC
            return -1
        }

        XCTAssertThrowsError(
            try ProjectMetadataStore.save(
                ProjectMetadata(title: "Initial", input: .video(files: [])),
                toProjectRootDescriptor: descriptor,
                operations: operations
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectMetadataBoundError,
                .persistence(
                    operation: "synchronize the project directory",
                    code: ENOSPC
                )
            )
        }

        XCTAssertEqual(try Data(contentsOf: paths.metadataURL), foreignBytes)
        XCTAssertEqual(
            try ProjectMetadataStore.load(
                from: root.appendingPathComponent("transaction-installed.json")
            ).title,
            "Initial"
        )
    }

    func testBoundSavePreservesReplacementRacedIntoCandidateQuarantine() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let foreignBytes = Data("foreign cleanup entry".utf8)
        let foreignLeaf = "foreign-cleanup-entry"
        try foreignBytes.write(
            to: root.appendingPathComponent(foreignLeaf),
            options: .withoutOverwriting
        )
        let descriptor = try openProjectRoot(root)
        defer { Darwin.close(descriptor) }
        let attempts = LockedCounter()
        let quarantineRaces = LockedCounter()
        let quarantineLeaf = LockedStringBox()
        let systemWrite = ProjectMetadataBoundOperations.system().write
        let systemRenameExclusive = ProjectMetadataBoundOperations.system()
            .renameExclusive
        var operations = ProjectMetadataBoundOperations.system()
        operations.write = { file, bytes, count in
            if attempts.increment() == 1 {
                return systemWrite(file, bytes, min(64, count))
            }
            errno = ENOSPC
            return -1
        }
        operations.renameExclusive = { rootDescriptor, source, destination in
            let result = systemRenameExclusive(
                rootDescriptor,
                source,
                destination
            )
            guard result == 0,
                  destination.hasPrefix(".project-metadata-quarantine-") else {
                return result
            }
            quarantineLeaf.set(destination)
            _ = quarantineRaces.increment()
            guard renameAt(
                rootDescriptor,
                destination,
                "transaction-candidate-preserved"
            ) == 0,
            renameAt(rootDescriptor, foreignLeaf, destination) == 0 else {
                return -1
            }
            return 0
        }

        XCTAssertThrowsError(
            try ProjectMetadataStore.save(
                ProjectMetadata(title: "Partial", input: .video(files: [])),
                toProjectRootDescriptor: descriptor,
                operations: operations
            )
        )

        XCTAssertEqual(quarantineRaces.value, 1)
        XCTAssertEqual(
            try Data(
                contentsOf: root.appendingPathComponent(quarantineLeaf.value)
            ),
            foreignBytes
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(
                    "transaction-candidate-preserved"
                ).path
            )
        )
    }

    func testBoundSaveReturnsSuccessWhenRetiredCleanupRaces() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Original", input: .video(files: [])),
            to: paths.metadataURL
        )
        let foreignBytes = Data("foreign retired cleanup entry".utf8)
        let foreignLeaf = "foreign-retired-entry"
        try foreignBytes.write(
            to: root.appendingPathComponent(foreignLeaf),
            options: .withoutOverwriting
        )
        let descriptor = try openProjectRoot(root)
        defer { Darwin.close(descriptor) }
        let quarantineRaces = LockedCounter()
        let quarantineLeaf = LockedStringBox()
        let systemRenameExclusive = ProjectMetadataBoundOperations.system()
            .renameExclusive
        var operations = ProjectMetadataBoundOperations.system()
        operations.renameExclusive = { rootDescriptor, source, destination in
            let result = systemRenameExclusive(
                rootDescriptor,
                source,
                destination
            )
            guard result == 0,
                  destination.hasPrefix(".project-metadata-quarantine-") else {
                return result
            }
            quarantineLeaf.set(destination)
            _ = quarantineRaces.increment()
            guard renameAt(
                rootDescriptor,
                destination,
                "retired-metadata-preserved"
            ) == 0,
            renameAt(rootDescriptor, foreignLeaf, destination) == 0 else {
                return -1
            }
            return 0
        }

        XCTAssertNoThrow(
            try ProjectMetadataStore.save(
                ProjectMetadata(title: "Updated", input: .video(files: [])),
                toProjectRootDescriptor: descriptor,
                operations: operations
            )
        )

        XCTAssertEqual(
            try ProjectMetadataStore.load(from: paths.metadataURL).title,
            "Updated"
        )
        XCTAssertEqual(quarantineRaces.value, 1)
        XCTAssertEqual(
            try Data(
                contentsOf: root.appendingPathComponent(quarantineLeaf.value)
            ),
            foreignBytes
        )
        XCTAssertEqual(
            try ProjectMetadataStore.load(
                from: root.appendingPathComponent("retired-metadata-preserved")
            ).title,
            "Original"
        )
    }

    func testBoundSaveReturnsSuccessWhenFinalCleanupSyncFails() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Original", input: .video(files: [])),
            to: paths.metadataURL
        )
        let descriptor = try openProjectRoot(root)
        defer { Darwin.close(descriptor) }
        let syncs = LockedCounter()
        let systemSynchronizeDirectory = ProjectMetadataBoundOperations.system()
            .synchronizeDirectory
        var operations = ProjectMetadataBoundOperations.system()
        operations.synchronizeDirectory = { rootDescriptor in
            if syncs.increment() == 1 {
                return systemSynchronizeDirectory(rootDescriptor)
            }
            errno = ENOSPC
            return -1
        }

        XCTAssertNoThrow(
            try ProjectMetadataStore.save(
                ProjectMetadata(title: "Updated", input: .video(files: [])),
                toProjectRootDescriptor: descriptor,
                operations: operations
            )
        )
        XCTAssertGreaterThan(syncs.value, 1)
        XCTAssertEqual(
            try ProjectMetadataStore.load(from: paths.metadataURL).title,
            "Updated"
        )
    }

    func testBoundSaveReconcilesThrowingPostCommitCheckpoints() throws {
        let checkpoints: [ProjectMetadataBoundCheckpoint] = [
            .committed,
            .directoryDurable,
            .canonicalValidated,
        ]
        for checkpoint in checkpoints {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let paths = ProjectPaths(root: root)
            try ProjectMetadataStore.save(
                ProjectMetadata(title: "Original", input: .video(files: [])),
                to: paths.metadataURL
            )
            let descriptor = try openProjectRoot(root)
            defer { Darwin.close(descriptor) }
            let injected = LockedFlag()
            var operations = ProjectMetadataBoundOperations.system()
            operations.didReachCheckpoint = { reached, _, _ in
                guard reached == checkpoint, injected.take() else { return }
                throw InjectedMetadataCheckpointError.expected
            }

            XCTAssertNoThrow(
                try ProjectMetadataStore.save(
                    ProjectMetadata(
                        title: "Updated at \(checkpoint)",
                        input: .video(files: [])
                    ),
                    toProjectRootDescriptor: descriptor,
                    operations: operations
                ),
                "Checkpoint \(checkpoint) must not bypass post-commit reconciliation."
            )
            XCTAssertEqual(
                try ProjectMetadataStore.load(from: paths.metadataURL).title,
                "Updated at \(checkpoint)"
            )
        }
    }

    func testBoundSaveClassifiesCanonicalReplacementFromThrowingCommitHook() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        let foreignRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: foreignRoot) }
        let foreignURL = ProjectPaths(root: foreignRoot).metadataURL
        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Foreign", input: .video(files: [])),
            to: foreignURL
        )
        let foreignBytes = try Data(contentsOf: foreignURL)
        let foreignLeaf = "foreign-project.json"
        try foreignBytes.write(
            to: root.appendingPathComponent(foreignLeaf),
            options: .withoutOverwriting
        )
        let descriptor = try openProjectRoot(root)
        defer { Darwin.close(descriptor) }
        var operations = ProjectMetadataBoundOperations.system()
        operations.didReachCheckpoint = { checkpoint, rootDescriptor, _ in
            guard checkpoint == .committed else { return }
            guard renameAt(
                rootDescriptor,
                "project.json",
                "transaction-installed.json"
            ) == 0,
            renameAt(rootDescriptor, foreignLeaf, "project.json") == 0 else {
                throw posixError()
            }
            throw InjectedMetadataCheckpointError.expected
        }

        XCTAssertThrowsError(
            try ProjectMetadataStore.save(
                ProjectMetadata(title: "Initial", input: .video(files: [])),
                toProjectRootDescriptor: descriptor,
                operations: operations
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectMetadataBoundError,
                .metadataConflict
            )
        }
        XCTAssertEqual(try Data(contentsOf: paths.metadataURL), foreignBytes)
        XCTAssertEqual(
            try ProjectMetadataStore.load(
                from: root.appendingPathComponent("transaction-installed.json")
            ).title,
            "Initial"
        )
    }

    func testBoundSaveFileSyncFailurePreservesCurrentMetadataAndCleansCandidate() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Original", input: .video(files: [])),
            to: paths.metadataURL
        )
        let originalBytes = try Data(contentsOf: paths.metadataURL)
        let descriptor = try openProjectRoot(root)
        defer { Darwin.close(descriptor) }
        var operations = ProjectMetadataBoundOperations.system()
        operations.synchronizeFile = { _ in
            errno = ENOSPC
            return -1
        }

        XCTAssertThrowsError(
            try ProjectMetadataStore.save(
                ProjectMetadata(title: "Updated", input: .video(files: [])),
                toProjectRootDescriptor: descriptor,
                operations: operations
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectMetadataBoundError,
                .persistence(
                    operation: "synchronize the metadata candidate",
                    code: ENOSPC
                )
            )
        }
        XCTAssertEqual(try Data(contentsOf: paths.metadataURL), originalBytes)
        XCTAssertTrue(try metadataCandidateLeaves(in: root).isEmpty)
    }

    func testBoundSaveDirectorySyncFailureRestoresCurrentMetadataAndCleansCandidate() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Original", input: .video(files: [])),
            to: paths.metadataURL
        )
        let originalBytes = try Data(contentsOf: paths.metadataURL)
        let descriptor = try openProjectRoot(root)
        defer { Darwin.close(descriptor) }
        var operations = ProjectMetadataBoundOperations.system()
        operations.synchronizeDirectory = { _ in
            errno = ENOSPC
            return -1
        }

        XCTAssertThrowsError(
            try ProjectMetadataStore.save(
                ProjectMetadata(title: "Updated", input: .video(files: [])),
                toProjectRootDescriptor: descriptor,
                operations: operations
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectMetadataBoundError,
                .persistence(
                    operation: "synchronize the project directory",
                    code: ENOSPC
                )
            )
        }
        XCTAssertEqual(try Data(contentsOf: paths.metadataURL), originalBytes)
        XCTAssertTrue(try metadataCandidateLeaves(in: root).isEmpty)
    }

    func testBoundSaveRejectsMutatedCandidateAndCleansOnlyItsInode() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Original", input: .video(files: [])),
            to: paths.metadataURL
        )
        let originalBytes = try Data(contentsOf: paths.metadataURL)
        let descriptor = try openProjectRoot(root)
        defer { Darwin.close(descriptor) }
        var operations = ProjectMetadataBoundOperations.system()
        operations.didReachCheckpoint = { checkpoint, rootDescriptor, candidate in
            guard checkpoint == .candidateDurable,
                  let candidate else { return }
            let file = candidate.withCString {
                Darwin.openat(
                    rootDescriptor,
                    $0,
                    O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard file >= 0 else { throw posixError() }
            defer { Darwin.close(file) }
            let foreign = Data("foreign candidate".utf8)
            let written = foreign.withUnsafeBytes {
                Darwin.write(file, $0.baseAddress, $0.count)
            }
            guard written == foreign.count else { throw posixError() }
        }

        XCTAssertThrowsError(
            try ProjectMetadataStore.save(
                ProjectMetadata(title: "Updated", input: .video(files: [])),
                toProjectRootDescriptor: descriptor,
                operations: operations
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectMetadataBoundError,
                .metadataChanged
            )
        }
        XCTAssertEqual(try Data(contentsOf: paths.metadataURL), originalBytes)
        XCTAssertTrue(try metadataCandidateLeaves(in: root).isEmpty)
    }

    func testBoundSaveRereadsCanonicalFileAfterDirectorySync() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        let foreignRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: foreignRoot) }
        let foreignURL = ProjectPaths(root: foreignRoot).metadataURL
        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Foreign", input: .video(files: [])),
            to: foreignURL
        )
        let foreignBytes = try Data(contentsOf: foreignURL)
        let foreignLeaf = "foreign-project.json"
        try foreignBytes.write(
            to: root.appendingPathComponent(foreignLeaf),
            options: .withoutOverwriting
        )
        let descriptor = try openProjectRoot(root)
        defer { Darwin.close(descriptor) }
        let candidateLeaf = LockedStringBox()
        var operations = ProjectMetadataBoundOperations.system()
        operations.didReachCheckpoint = { checkpoint, rootDescriptor, candidate in
            if checkpoint == .candidateValidated, let candidate {
                candidateLeaf.set(candidate)
            } else if checkpoint == .directoryDurable {
                guard renameAt(
                    rootDescriptor,
                    "project.json",
                    "committed-by-store.json"
                ) == 0,
                renameAt(
                    rootDescriptor,
                    foreignLeaf,
                    "project.json"
                ) == 0 else {
                    throw posixError()
                }
            }
        }

        XCTAssertThrowsError(
            try ProjectMetadataStore.save(
                ProjectMetadata(title: "Candidate", input: .video(files: [])),
                toProjectRootDescriptor: descriptor,
                operations: operations
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectMetadataBoundError,
                .metadataConflict
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: paths.metadataURL),
            foreignBytes
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(candidateLeaf.value).path
            )
        )
        XCTAssertEqual(
            try ProjectMetadataStore.load(
                from: root.appendingPathComponent("committed-by-store.json")
            ).title,
            "Candidate"
        )
    }

    func testBoundSaveRestoresPriorMetadataAfterCanonicalReplacement() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ProjectPaths(root: root)
        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Original", input: .video(files: [])),
            to: paths.metadataURL
        )
        let originalBytes = try Data(contentsOf: paths.metadataURL)

        let foreignRoot = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: foreignRoot) }
        let foreignURL = ProjectPaths(root: foreignRoot).metadataURL
        try ProjectMetadataStore.save(
            ProjectMetadata(title: "Foreign", input: .video(files: [])),
            to: foreignURL
        )
        let foreignBytes = try Data(contentsOf: foreignURL)
        let foreignLeaf = "foreign-project.json"
        try foreignBytes.write(
            to: root.appendingPathComponent(foreignLeaf),
            options: .withoutOverwriting
        )

        let descriptor = try openProjectRoot(root)
        defer { Darwin.close(descriptor) }
        let candidateLeaf = LockedStringBox()
        var operations = ProjectMetadataBoundOperations.system()
        operations.didReachCheckpoint = { checkpoint, rootDescriptor, candidate in
            if checkpoint == .candidateValidated, let candidate {
                candidateLeaf.set(candidate)
            } else if checkpoint == .directoryDurable {
                guard renameAt(
                    rootDescriptor,
                    "project.json",
                    "committed-by-store.json"
                ) == 0,
                renameAt(
                    rootDescriptor,
                    foreignLeaf,
                    "project.json"
                ) == 0 else {
                    throw posixError()
                }
            }
        }

        XCTAssertThrowsError(
            try ProjectMetadataStore.save(
                ProjectMetadata(title: "Candidate", input: .video(files: [])),
                toProjectRootDescriptor: descriptor,
                operations: operations
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectMetadataBoundError,
                .metadataConflict
            )
        }
        XCTAssertEqual(try Data(contentsOf: paths.metadataURL), originalBytes)
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent(candidateLeaf.value)),
            foreignBytes
        )
        XCTAssertEqual(
            try ProjectMetadataStore.load(
                from: root.appendingPathComponent("committed-by-store.json")
            ).title,
            "Candidate"
        )
    }

    func testBoundLoadRejectsSymlinkAndFIFOProjectMetadata() throws {
        for fixture in ["symlink", "fifo"] {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            let metadataURL = ProjectPaths(root: root).metadataURL
            if fixture == "symlink" {
                let outside = root.appendingPathComponent("outside.json")
                try Data("{}".utf8).write(to: outside)
                try FileManager.default.createSymbolicLink(
                    at: metadataURL,
                    withDestinationURL: outside
                )
            } else {
                XCTAssertEqual(Darwin.mkfifo(metadataURL.path, mode_t(0o600)), 0)
            }
            let descriptor = try openProjectRoot(root)
            XCTAssertThrowsError(
                try ProjectMetadataStore.load(
                    fromProjectRootDescriptor: descriptor
                ),
                fixture
            )
            Darwin.close(descriptor)
        }
    }

    func testBoundLoadRejectsOversizedProjectMetadata() throws {
        let root = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0x20, count: 8 * 1_024 * 1_024 + 1)
            .write(to: ProjectPaths(root: root).metadataURL)
        let descriptor = try openProjectRoot(root)
        defer { Darwin.close(descriptor) }

        XCTAssertThrowsError(
            try ProjectMetadataStore.load(
                fromProjectRootDescriptor: descriptor
            )
        ) { error in
            XCTAssertEqual(
                error as? ProjectMetadataBoundError,
                .unsafeMetadata
            )
        }
    }

    func testBoundLoadPreservesStrictMalformedAndFutureFormatFailures() throws {
        let cases: [(name: String, data: Data)] = [
            (
                "malformed",
                Data(#"{"formatVersion":33,"title":"bad","title":"duplicate"}"#.utf8)
            ),
            (
                "future",
                Data(#"{"formatVersion":999,"newRequiredField":true}"#.utf8)
            ),
        ]
        for testCase in cases {
            let root = try TestFileBuilder.makeTempDir()
            defer { try? FileManager.default.removeItem(at: root) }
            try testCase.data.write(to: ProjectPaths(root: root).metadataURL)
            let descriptor = try openProjectRoot(root)
            XCTAssertThrowsError(
                try ProjectMetadataStore.load(
                    fromProjectRootDescriptor: descriptor
                ),
                testCase.name
            ) { error in
                switch testCase.name {
                case "malformed":
                    guard case ProjectMetadataStore.LoadError.malformedJSON = error else {
                        return XCTFail("Expected malformedJSON, got \(error)")
                    }
                default:
                    guard case ProjectMetadataStore.LoadError.unsupportedFormatVersion(999) = error else {
                        return XCTFail("Expected future-format rejection, got \(error)")
                    }
                }
            }
            Darwin.close(descriptor)
        }
    }
}

private enum InjectedMetadataCheckpointError: Error {
    case expected
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true

    func take() -> Bool {
        lock.withLock {
            defer { value = false }
            return value
        }
    }
}

private final class LockedErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Error] = []

    var values: [Error] {
        lock.withLock { storage }
    }

    func append(_ error: Error) {
        lock.withLock { storage.append(error) }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.withLock { storage }
    }

    @discardableResult
    func increment() -> Int {
        lock.withLock {
            storage += 1
            return storage
        }
    }
}

private final class LockedStringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    var value: String {
        lock.withLock { storage ?? "" }
    }

    func set(_ value: String) {
        lock.withLock { storage = value }
    }
}

private func openProjectRoot(_ root: URL) throws -> Int32 {
    let descriptor = Darwin.open(
        root.path,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else { throw posixError() }
    return descriptor
}

private func metadataCandidateLeaves(in root: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: root.path)
        .filter { $0.hasPrefix(".project-metadata-") }
}

private func posixError() -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
}

private func renameAt(
    _ rootDescriptor: Int32,
    _ source: String,
    _ destination: String
) -> Int32 {
    source.withCString { sourcePointer in
        destination.withCString { destinationPointer in
            Darwin.renameat(
                rootDescriptor,
                sourcePointer,
                rootDescriptor,
                destinationPointer
            )
        }
    }
}
