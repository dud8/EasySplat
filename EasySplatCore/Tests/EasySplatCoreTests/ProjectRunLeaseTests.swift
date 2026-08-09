#if canImport(XCTest)
import Darwin
import Foundation
import XCTest
@testable import EasySplatCore

final class ProjectRunLeaseTests: XCTestCase {
    func testLeaseExcludesAnotherProcessAndReleasesForIt() throws {
        let fixture = try makeFixture(projectName: "CrossProcess.easysplatproj")
        defer { fixture.remove() }
        let lease = try ProjectRunLease.acquire(
            projectURL: fixture.projectURL,
            registryURL: fixture.registryURL
        )
        defer { lease.release() }

        try runCrossProcessHelper(mode: "blocked", fixture: fixture)
        lease.release()
        try runCrossProcessHelper(mode: "available", fixture: fixture)
    }

    func testCrossProcessAcquireHelperEntryPoint() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let mode = environment["EASYSPLAT_RUN_LEASE_HELPER_MODE"],
              let projectPath = environment["EASYSPLAT_RUN_LEASE_HELPER_PROJECT"],
              let registryPath = environment["EASYSPLAT_RUN_LEASE_HELPER_REGISTRY"] else {
            return
        }
        let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
        let registryURL = URL(fileURLWithPath: registryPath, isDirectory: true)

        do {
            let lease = try ProjectRunLease.acquire(
                projectURL: projectURL,
                registryURL: registryURL
            )
            defer { lease.release() }
            XCTAssertEqual(mode, "available")
        } catch {
            guard mode == "blocked" else { throw error }
            XCTAssertEqual(error as? ProjectRunLeaseError, .alreadyRunning)
        }
    }

    func testLeaseKeyContainsNoProjectPathOrIdentity() throws {
        let fixture = try makeFixture(
            projectName: "Client Acme Secret 01234567-89AB-CDEF-0123-456789ABCDEF.easysplatproj"
        )
        defer { fixture.remove() }

        let lease = try ProjectRunLease.acquire(
            projectURL: fixture.projectURL,
            registryURL: fixture.registryURL
        )
        lease.release()

        let entries = try fixture.registryEntries()
        XCTAssertFalse(entries.isEmpty)
        for entry in entries {
            XCTAssertNotNil(
                entry.range(
                    of: #"^[0-9a-f]{64}\.lock$"#,
                    options: .regularExpression
                )
            )
            XCTAssertFalse(entry.localizedCaseInsensitiveContains("Acme"))
            XCTAssertFalse(entry.contains("01234567-89AB-CDEF-0123-456789ABCDEF"))
        }
    }

    func testLeaseRejectsDotComponentsWithoutFollowingThem() throws {
        let fixture = try makeFixture(
            projectName: "DotComponents.easysplatproj"
        )
        defer { fixture.remove() }
        let nonNormalizedURL = URL(
            fileURLWithPath: fixture.rootURL
                .appendingPathComponent("unused", isDirectory: true)
                .appendingPathComponent("..", isDirectory: true)
                .appendingPathComponent(
                    fixture.projectURL.lastPathComponent,
                    isDirectory: true
                )
                .path,
            isDirectory: true
        )

        assertLeaseError(.unsafeProject) {
            try ProjectRunLease.acquire(
                projectURL: nonNormalizedURL,
                registryURL: fixture.registryURL
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.registryURL.path))
    }

    func testCaseDistinctProjectPathsAcquireIndependentLeases() throws {
        let volume = try CaseSensitiveVolumeFixture.create()
        defer { volume.remove() }
        let upperProjectURL = volume.mountURL.appendingPathComponent(
            "CaseDistinct.easysplatproj",
            isDirectory: true
        )
        let lowerProjectURL = volume.mountURL.appendingPathComponent(
            "casedistinct.easysplatproj",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: upperProjectURL,
            withIntermediateDirectories: false
        )
        try FileManager.default.createDirectory(
            at: lowerProjectURL,
            withIntermediateDirectories: false
        )

        let upperLease = try ProjectRunLease.acquire(
            projectURL: upperProjectURL,
            registryURL: volume.registryURL
        )
        defer { upperLease.release() }
        let lowerLease = try ProjectRunLease.acquire(
            projectURL: lowerProjectURL,
            registryURL: volume.registryURL
        )
        defer { lowerLease.release() }

        assertLeaseError(.alreadyRunning) {
            try ProjectRunLease.acquire(
                projectURL: upperProjectURL,
                registryURL: volume.registryURL
            )
        }
        assertLeaseError(.alreadyRunning) {
            try ProjectRunLease.acquire(
                projectURL: lowerProjectURL,
                registryURL: volume.registryURL
            )
        }
    }

    func testSameProjectThroughTmpAliasUsesOneLocationLock() throws {
        let fixture = try makeTmpAliasFixture(
            projectName: "TmpAliasIntact.easysplatproj"
        )
        defer { fixture.remove() }

        let lease = try ProjectRunLease.acquire(
            projectURL: fixture.aliasProjectURL,
            registryURL: fixture.registryURL
        )
        defer { lease.release() }

        assertLeaseError(.alreadyRunning) {
            try ProjectRunLease.acquire(
                projectURL: fixture.canonicalProjectURL,
                registryURL: fixture.registryURL
            )
        }
        let lockedPath = try lease.withLockedProjectRootDescriptor {
            try descriptorPath($0)
        }
        XCTAssertEqual(lockedPath, fixture.canonicalProjectURL.path)
        XCTAssertFalse(try fixture.registryEntries().isEmpty)
    }

    func testTmpAliasRemainsExclusiveAfterCanonicalProjectReplacement() throws {
        let fixture = try makeTmpAliasFixture(
            projectName: "TmpAliasReplacement.easysplatproj"
        )
        defer { fixture.remove() }
        let movedURL = fixture.canonicalRootURL.appendingPathComponent(
            "TmpAliasReplacement-moved.easysplatproj",
            isDirectory: true
        )

        let lease = try ProjectRunLease.acquire(
            projectURL: fixture.aliasProjectURL,
            registryURL: fixture.registryURL
        )
        defer { lease.release() }
        try FileManager.default.moveItem(
            at: fixture.canonicalProjectURL,
            to: movedURL
        )
        try FileManager.default.createDirectory(
            at: fixture.canonicalProjectURL,
            withIntermediateDirectories: false
        )

        assertLeaseError(.alreadyRunning) {
            try ProjectRunLease.acquire(
                projectURL: fixture.canonicalProjectURL,
                registryURL: fixture.registryURL
            )
        }
        assertLeaseError(.unsafeProject) {
            try lease.revalidateProjectRoot()
        }
        XCTAssertFalse(try fixture.registryEntries().isEmpty)
    }

    func testAliasedRegistryParentAnchorExcludesCanonicalReplacementCrossProcess() throws {
        let fixture = try makeTmpAliasFixture(
            projectName: "AliasedRegistryReplacement.easysplatproj"
        )
        defer { fixture.remove() }
        let aliasRegistryURL = fixture.aliasProjectURL
            .deletingLastPathComponent()
            .appendingPathComponent("lease-registry", isDirectory: true)
        let movedProjectURL = fixture.canonicalRootURL.appendingPathComponent(
            "AliasedRegistryReplacement-moved.easysplatproj",
            isDirectory: true
        )
        let movedRegistryURL = fixture.canonicalRootURL.appendingPathComponent(
            "lease-registry-moved",
            isDirectory: true
        )

        let lease = try ProjectRunLease.acquire(
            projectURL: fixture.aliasProjectURL,
            registryURL: aliasRegistryURL
        )
        defer { lease.release() }
        try FileManager.default.moveItem(
            at: fixture.canonicalProjectURL,
            to: movedProjectURL
        )
        try FileManager.default.createDirectory(
            at: fixture.canonicalProjectURL,
            withIntermediateDirectories: false
        )
        try FileManager.default.moveItem(
            at: fixture.registryURL,
            to: movedRegistryURL
        )
        try FileManager.default.createDirectory(
            at: fixture.registryURL,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(
            Darwin.chmod(fixture.registryURL.path, mode_t(0o700)),
            0
        )

        try runCrossProcessHelper(
            mode: "blocked",
            fixture: Fixture(
                rootURL: fixture.canonicalRootURL,
                projectURL: fixture.canonicalProjectURL,
                registryURL: fixture.registryURL
            )
        )
        assertLeaseError(.unsafeProject) {
            try lease.revalidateProjectRoot()
        }
    }

    func testCaseAliasRemainsExclusiveAfterProjectReplacementWhenVolumeIsCaseInsensitive() throws {
        let fixture = try makeFixture(
            projectName: "CaseAliasReplacement.easysplatproj"
        )
        defer { fixture.remove() }
        let aliasURL = fixture.projectURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                fixture.projectURL.lastPathComponent.lowercased(),
                isDirectory: true
            )
        guard try pathsNameSameDirectory(
            fixture.projectURL.path,
            aliasURL.path
        ) else {
            throw XCTSkip("The test fixture volume is case-sensitive.")
        }
        let movedURL = fixture.rootURL.appendingPathComponent(
            "CaseAliasReplacement-moved.easysplatproj",
            isDirectory: true
        )

        let lease = try ProjectRunLease.acquire(
            projectURL: fixture.projectURL,
            registryURL: fixture.registryURL
        )
        defer { lease.release() }
        try FileManager.default.moveItem(at: fixture.projectURL, to: movedURL)
        try FileManager.default.createDirectory(
            at: aliasURL,
            withIntermediateDirectories: false
        )

        assertLeaseError(.alreadyRunning) {
            try ProjectRunLease.acquire(
                projectURL: aliasURL,
                registryURL: fixture.registryURL
            )
        }
        try runCrossProcessHelper(
            mode: "blocked",
            fixture: fixture,
            projectURL: aliasURL
        )
        XCTAssertGreaterThanOrEqual(try fixture.registryEntries().count, 2)
    }

    func testUnicodeAliasRemainsExclusiveAfterProjectReplacement() throws {
        let fixture = try makeFixture(projectName: "Caf\u{00E9}.easysplatproj")
        defer { fixture.remove() }
        let decomposedURL = fixture.projectURL
            .deletingLastPathComponent()
            .appendingPathComponent("Cafe\u{0301}.easysplatproj", isDirectory: true)
        guard try pathsNameSameDirectory(
            fixture.projectURL.path,
            decomposedURL.path
        ) else {
            throw XCTSkip("The test fixture volume distinguishes Unicode normalization forms.")
        }
        let movedURL = fixture.rootURL.appendingPathComponent(
            "UnicodeAliasReplacement-moved.easysplatproj",
            isDirectory: true
        )
        let lease = try ProjectRunLease.acquire(
            projectURL: fixture.projectURL,
            registryURL: fixture.registryURL
        )
        defer { lease.release() }
        try FileManager.default.moveItem(at: fixture.projectURL, to: movedURL)
        try FileManager.default.createDirectory(
            at: decomposedURL,
            withIntermediateDirectories: false
        )

        assertLeaseError(.alreadyRunning) {
            try ProjectRunLease.acquire(
                projectURL: decomposedURL,
                registryURL: fixture.registryURL
            )
        }
        try runCrossProcessHelper(
            mode: "blocked",
            fixture: fixture,
            projectURL: decomposedURL
        )
    }

    func testRevalidationRejectsSuppliedAncestorSymlinkRetarget() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EasySplat-ProjectRunLeaseSymlinkTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let originalParentURL = rootURL.appendingPathComponent(
            "original-parent",
            isDirectory: true
        )
        let replacementParentURL = rootURL.appendingPathComponent(
            "replacement-parent",
            isDirectory: true
        )
        let suppliedParentURL = rootURL.appendingPathComponent(
            "selected-parent",
            isDirectory: true
        )
        let projectLeaf = "Retargeted.easysplatproj"
        let originalProjectURL = originalParentURL.appendingPathComponent(
            projectLeaf,
            isDirectory: true
        )
        let replacementProjectURL = replacementParentURL.appendingPathComponent(
            projectLeaf,
            isDirectory: true
        )
        let suppliedProjectURL = suppliedParentURL.appendingPathComponent(
            projectLeaf,
            isDirectory: true
        )
        let registryURL = rootURL.appendingPathComponent(
            "lease-registry",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: originalProjectURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: replacementProjectURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: suppliedParentURL,
            withDestinationURL: originalParentURL
        )

        let lease = try ProjectRunLease.acquire(
            projectURL: suppliedProjectURL,
            registryURL: registryURL
        )
        defer { lease.release() }
        XCTAssertTrue(
            try pathsNameSameDirectory(
                lease.withLockedProjectRootDescriptor { try descriptorPath($0) },
                originalProjectURL.path
            )
        )

        try FileManager.default.removeItem(at: suppliedParentURL)
        try FileManager.default.createSymbolicLink(
            at: suppliedParentURL,
            withDestinationURL: replacementParentURL
        )

        assertLeaseError(.unsafeProject) {
            try lease.revalidateProjectRoot()
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalProjectURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: replacementProjectURL.path))
    }

    func testAncestorSymlinkRetargetCannotAcquireSecondLease() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EasySplat-ProjectRunLeaseRetargetTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let originalParentURL = rootURL.appendingPathComponent("original", isDirectory: true)
        let replacementParentURL = rootURL.appendingPathComponent("replacement", isDirectory: true)
        let selectedParentURL = rootURL.appendingPathComponent("selected", isDirectory: true)
        let projectLeaf = "Retargeted.easysplatproj"
        let originalProjectURL = originalParentURL.appendingPathComponent(projectLeaf, isDirectory: true)
        let replacementProjectURL = replacementParentURL.appendingPathComponent(projectLeaf, isDirectory: true)
        let selectedProjectURL = selectedParentURL.appendingPathComponent(projectLeaf, isDirectory: true)
        let registryURL = rootURL.appendingPathComponent("lease-registry", isDirectory: true)
        try FileManager.default.createDirectory(at: originalProjectURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacementProjectURL, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: selectedParentURL,
            withDestinationURL: originalParentURL
        )

        let lease = try ProjectRunLease.acquire(
            projectURL: selectedProjectURL,
            registryURL: registryURL
        )
        defer { lease.release() }
        try FileManager.default.removeItem(at: selectedParentURL)
        try FileManager.default.createSymbolicLink(
            at: selectedParentURL,
            withDestinationURL: replacementParentURL
        )

        assertLeaseError(.alreadyRunning) {
            try ProjectRunLease.acquire(
                projectURL: selectedProjectURL,
                registryURL: registryURL
            )
        }
        try runCrossProcessHelper(
            mode: "blocked",
            fixture: Fixture(
                rootURL: rootURL,
                projectURL: selectedProjectURL,
                registryURL: registryURL
            )
        )
        assertLeaseError(.unsafeProject) {
            try lease.revalidateProjectRoot()
        }
    }

    func testAncestorAliasRemainsExclusiveAfterCanonicalProjectReplacement() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EasySplat-ProjectRunLeaseLocationAliasTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let canonicalParentURL = rootURL.appendingPathComponent(
            "canonical-parent",
            isDirectory: true
        )
        let aliasParentURL = rootURL.appendingPathComponent(
            "alias-parent",
            isDirectory: true
        )
        let projectLeaf = "AliasedReplacement.easysplatproj"
        let canonicalProjectURL = canonicalParentURL.appendingPathComponent(
            projectLeaf,
            isDirectory: true
        )
        let aliasProjectURL = aliasParentURL.appendingPathComponent(
            projectLeaf,
            isDirectory: true
        )
        let movedProjectURL = canonicalParentURL.appendingPathComponent(
            "AliasedReplacement-moved.easysplatproj",
            isDirectory: true
        )
        let registryURL = rootURL.appendingPathComponent(
            "lease-registry",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: canonicalProjectURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: aliasParentURL,
            withDestinationURL: canonicalParentURL
        )

        let lease = try ProjectRunLease.acquire(
            projectURL: aliasProjectURL,
            registryURL: registryURL
        )
        defer { lease.release() }
        try FileManager.default.moveItem(
            at: canonicalProjectURL,
            to: movedProjectURL
        )
        try FileManager.default.createDirectory(
            at: canonicalProjectURL,
            withIntermediateDirectories: false
        )

        assertLeaseError(.alreadyRunning) {
            try ProjectRunLease.acquire(
                projectURL: canonicalProjectURL,
                registryURL: registryURL
            )
        }
        assertLeaseError(.unsafeProject) {
            try lease.revalidateProjectRoot()
        }
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: registryURL.path).isEmpty
        )
    }

    func testLeaseRemainsExclusiveAfterProjectPathReplacement() throws {
        let fixture = try makeFixture(projectName: "Replace.easysplatproj")
        defer { fixture.remove() }
        let movedURL = fixture.rootURL.appendingPathComponent(
            "Replace-moved.easysplatproj",
            isDirectory: true
        )

        let firstLease = try ProjectRunLease.acquire(
            projectURL: fixture.projectURL,
            registryURL: fixture.registryURL
        )
        defer { firstLease.release() }
        try FileManager.default.moveItem(at: fixture.projectURL, to: movedURL)
        try FileManager.default.createDirectory(
            at: fixture.projectURL,
            withIntermediateDirectories: false
        )

        assertLeaseError(.alreadyRunning) {
            try ProjectRunLease.acquire(
                projectURL: fixture.projectURL,
                registryURL: fixture.registryURL
            )
        }
        try runCrossProcessHelper(mode: "blocked", fixture: fixture)
        assertLeaseError(.unsafeProject) {
            try firstLease.revalidateProjectRoot()
        }
    }

    func testDetachedLeaseStaysInvalidAfterOriginalRootIsRestored() throws {
        let fixture = try makeFixture(projectName: "StickyFailure.easysplatproj")
        defer { fixture.remove() }
        let movedURL = fixture.rootURL.appendingPathComponent(
            "StickyFailure-moved.easysplatproj",
            isDirectory: true
        )
        let lease = try ProjectRunLease.acquire(
            projectURL: fixture.projectURL,
            registryURL: fixture.registryURL
        )
        defer { lease.release() }
        try FileManager.default.moveItem(at: fixture.projectURL, to: movedURL)
        try FileManager.default.createDirectory(
            at: fixture.projectURL,
            withIntermediateDirectories: false
        )
        assertLeaseError(.unsafeProject) {
            try lease.revalidateProjectRoot()
        }

        try FileManager.default.removeItem(at: fixture.projectURL)
        try FileManager.default.moveItem(at: movedURL, to: fixture.projectURL)
        assertLeaseError(.unsafeProject) {
            try lease.revalidateProjectRoot()
        }
    }

    func testLockedProjectRootDescriptorIsDuplicatedCloseOnExecAndClosedAfterUse() throws {
        let fixture = try makeFixture(
            projectName: "BorrowedDescriptor.easysplatproj"
        )
        defer { fixture.remove() }
        let lease = try ProjectRunLease.acquire(
            projectURL: fixture.projectURL,
            registryURL: fixture.registryURL
        )
        defer { lease.release() }
        var duplicate = Int32(-1)

        let openedIdentity = try lease.withLockedProjectRootDescriptor {
            duplicate = $0
            let descriptorFlags = Darwin.fcntl($0, F_GETFD)
            XCTAssertGreaterThanOrEqual(descriptorFlags, 0)
            XCTAssertNotEqual(descriptorFlags & FD_CLOEXEC, 0)
            var opened = stat()
            guard Darwin.fstat($0, &opened) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return (opened.st_dev, opened.st_ino)
        }

        var named = stat()
        XCTAssertEqual(Darwin.lstat(fixture.projectURL.path, &named), 0)
        XCTAssertEqual(openedIdentity.0, named.st_dev)
        XCTAssertEqual(openedIdentity.1, named.st_ino)
        errno = 0
        XCTAssertEqual(Darwin.fcntl(duplicate, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)
        XCTAssertNoThrow(try lease.revalidateProjectRoot())
    }

    func testLockedProjectRootDescriptorFailsClosedAfterCanonicalReplacement() throws {
        let fixture = try makeFixture(
            projectName: "DescriptorReplacement.easysplatproj"
        )
        defer { fixture.remove() }
        let movedURL = fixture.rootURL.appendingPathComponent(
            "DescriptorReplacement-moved.easysplatproj",
            isDirectory: true
        )
        let lease = try ProjectRunLease.acquire(
            projectURL: fixture.projectURL,
            registryURL: fixture.registryURL
        )
        defer { lease.release() }

        assertLeaseError(.unsafeProject) {
            try lease.withLockedProjectRootDescriptor { _ in
                try FileManager.default.moveItem(
                    at: fixture.projectURL,
                    to: movedURL
                )
                try FileManager.default.createDirectory(
                    at: fixture.projectURL,
                    withIntermediateDirectories: false
                )
            }
        }
        assertLeaseError(.unsafeProject) {
            try lease.revalidateProjectRoot()
        }
    }

    func testLockedProjectRootDescriptorRejectsUseAfterRelease() throws {
        let fixture = try makeFixture(
            projectName: "ReleasedDescriptor.easysplatproj"
        )
        defer { fixture.remove() }
        let lease = try ProjectRunLease.acquire(
            projectURL: fixture.projectURL,
            registryURL: fixture.registryURL
        )
        lease.release()

        assertLeaseError(.unsafeProject) {
            try lease.withLockedProjectRootDescriptor { _ in () }
        }
    }

    func testLockedProjectRootDescriptorPropagatesOperationFailureWhenBindingsRemainValid() throws {
        let fixture = try makeFixture(
            projectName: "DescriptorFailure.easysplatproj"
        )
        defer { fixture.remove() }
        let lease = try ProjectRunLease.acquire(
            projectURL: fixture.projectURL,
            registryURL: fixture.registryURL
        )
        defer { lease.release() }

        do {
            let _: Void = try lease.withLockedProjectRootDescriptor { _ in
                throw CocoaError(.fileReadUnknown)
            }
            XCTFail("Expected the descriptor-relative operation to fail.")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileReadUnknown)
        }
        XCTAssertNoThrow(try lease.revalidateProjectRoot())
    }

    func testValidatedProjectRootDescriptorDoesNotHoldStateLockAndDefersRelease() throws {
        let fixture = try makeFixture(projectName: "DescriptorLoan.easysplatproj")
        defer { fixture.remove() }
        let lease = try ProjectRunLease.acquire(
            projectURL: fixture.projectURL,
            registryURL: fixture.registryURL
        )
        let entered = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        let result = LockedTestBox<Result<Void, Error>?>(nil)
        let loanedDescriptor = LockedTestBox<Int32>(-1)

        DispatchQueue.global(qos: .userInitiated).async {
            result.value = Result {
                try lease.withValidatedProjectRootDescriptor { descriptor in
                    loanedDescriptor.value = descriptor
                    entered.signal()
                    guard finish.wait(timeout: .now() + 5) == .success else {
                        throw CocoaError(.fileReadUnknown)
                    }
                }
            }
            completed.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)

        let released = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            lease.release()
            released.signal()
        }
        XCTAssertEqual(
            released.wait(timeout: .now() + 1),
            .success,
            "release() must not wait for descriptor-relative publication work"
        )
        assertLeaseError(.alreadyRunning) {
            try ProjectRunLease.acquire(
                projectURL: fixture.projectURL,
                registryURL: fixture.registryURL
            )
        }
        try runCrossProcessHelper(mode: "blocked", fixture: fixture)

        finish.signal()
        XCTAssertEqual(completed.wait(timeout: .now() + 5), .success)
        try result.value?.get()
        errno = 0
        XCTAssertEqual(Darwin.fcntl(loanedDescriptor.value, F_GETFD), -1)
        XCTAssertEqual(errno, EBADF)

        let replacement = try ProjectRunLease.acquire(
            projectURL: fixture.projectURL,
            registryURL: fixture.registryURL
        )
        replacement.release()
    }

    func testValidatedProjectRootDescriptorPostflightInvalidatesReplacement() throws {
        let fixture = try makeFixture(projectName: "DescriptorLoanReplacement.easysplatproj")
        defer { fixture.remove() }
        let movedURL = fixture.rootURL.appendingPathComponent(
            "DescriptorLoanReplacement-moved.easysplatproj",
            isDirectory: true
        )
        let lease = try ProjectRunLease.acquire(
            projectURL: fixture.projectURL,
            registryURL: fixture.registryURL
        )
        defer { lease.release() }

        assertLeaseError(.unsafeProject) {
            try lease.withValidatedProjectRootDescriptor { _ in
                try FileManager.default.moveItem(at: fixture.projectURL, to: movedURL)
                try FileManager.default.createDirectory(
                    at: fixture.projectURL,
                    withIntermediateDirectories: false
                )
            }
        }
        assertLeaseError(.unsafeProject) {
            try lease.revalidateProjectRoot()
        }
    }

    func testConcurrentDescriptorLoanFinalizationPreservesStickyInvalidation() throws {
        let fixture = try makeFixture(
            projectName: "ConcurrentDescriptorLoans.easysplatproj"
        )
        defer { fixture.remove() }
        let movedURL = fixture.rootURL.appendingPathComponent(
            "ConcurrentDescriptorLoans-moved.easysplatproj",
            isDirectory: true
        )
        let lease = try ProjectRunLease.acquire(
            projectURL: fixture.projectURL,
            registryURL: fixture.registryURL
        )
        defer { lease.release() }
        let firstEntered = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let mutateFirst = DispatchSemaphore(value: 0)
        let finishSecond = DispatchSemaphore(value: 0)
        let firstCompleted = DispatchSemaphore(value: 0)
        let secondCompleted = DispatchSemaphore(value: 0)
        let firstResult = LockedTestBox<Result<Void, Error>?>(nil)
        let secondResult = LockedTestBox<Result<Void, Error>?>(nil)

        DispatchQueue.global(qos: .userInitiated).async {
            firstResult.value = Result {
                try lease.withValidatedProjectRootDescriptor { _ in
                    firstEntered.signal()
                    guard mutateFirst.wait(timeout: .now() + 5) == .success else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    try FileManager.default.moveItem(
                        at: fixture.projectURL,
                        to: movedURL
                    )
                    try FileManager.default.createDirectory(
                        at: fixture.projectURL,
                        withIntermediateDirectories: false
                    )
                }
            }
            firstCompleted.signal()
        }
        DispatchQueue.global(qos: .userInitiated).async {
            secondResult.value = Result {
                try lease.withValidatedProjectRootDescriptor { _ in
                    secondEntered.signal()
                    guard finishSecond.wait(timeout: .now() + 5) == .success else {
                        throw CocoaError(.fileReadUnknown)
                    }
                    throw CocoaError(.fileReadUnknown)
                }
            }
            secondCompleted.signal()
        }

        XCTAssertEqual(firstEntered.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 5), .success)
        mutateFirst.signal()
        XCTAssertEqual(firstCompleted.wait(timeout: .now() + 5), .success)
        guard case .failure(let firstError)? = firstResult.value else {
            XCTFail("The first descriptor loan should invalidate the lease.")
            finishSecond.signal()
            _ = secondCompleted.wait(timeout: .now() + 5)
            return
        }
        XCTAssertEqual(firstError as? ProjectRunLeaseError, .unsafeProject)

        try FileManager.default.removeItem(at: fixture.projectURL)
        try FileManager.default.moveItem(at: movedURL, to: fixture.projectURL)
        finishSecond.signal()
        XCTAssertEqual(secondCompleted.wait(timeout: .now() + 5), .success)
        guard case .failure(let secondError)? = secondResult.value else {
            XCTFail("A concurrent descriptor loan must observe sticky invalidation.")
            return
        }
        XCTAssertEqual(secondError as? ProjectRunLeaseError, .unsafeProject)
        assertLeaseError(.unsafeProject) {
            try lease.revalidateProjectRoot()
        }
    }

    func testEveryRetainedAndLoanedDescriptorIsClosedByRealExec() throws {
        let fixture = try makeFixture(projectName: "CloseOnExec.easysplatproj")
        defer { fixture.remove() }
        let lease = try ProjectRunLease.acquire(
            projectURL: fixture.projectURL,
            registryURL: fixture.registryURL
        )
        defer { lease.release() }
        let snapshots = try lease.retainedDescriptorSnapshotsForTesting()
        XCTAssertGreaterThanOrEqual(snapshots.count, 5)
        for snapshot in snapshots {
            let flags = Darwin.fcntl(snapshot.descriptor, F_GETFD)
            XCTAssertGreaterThanOrEqual(flags, 0)
            XCTAssertNotEqual(flags & FD_CLOEXEC, 0)
        }

        let helperURL = try buildDescriptorExecProbe(in: fixture.rootURL)
        let arguments = snapshots.map {
            "\($0.descriptor):\($0.device):\($0.inode)"
        }
        XCTAssertEqual(try runExecProbe(helperURL: helperURL, arguments: arguments), 0)
        XCTAssertEqual(
            try lease.withLockedProjectRootDescriptor { descriptor in
                try runExecProbe(
                    helperURL: helperURL,
                    arguments: [try descriptorArgument(descriptor)]
                )
            },
            0
        )
        XCTAssertEqual(
            try lease.withValidatedProjectRootDescriptor { descriptor in
                try runExecProbe(
                    helperURL: helperURL,
                    arguments: [try descriptorArgument(descriptor)]
                )
            },
            0
        )
    }

    func testUnsafeRegistryFailureReleasesEarlyProjectLock() throws {
        let fixture = try makeFixture(
            projectName: "RegistryRollback.easysplatproj"
        )
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.registryURL,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(Darwin.chmod(fixture.registryURL.path, mode_t(0o755)), 0)

        assertLeaseError(.unsafeProject) {
            try ProjectRunLease.acquire(
                projectURL: fixture.projectURL,
                registryURL: fixture.registryURL
            )
        }

        XCTAssertEqual(Darwin.chmod(fixture.registryURL.path, mode_t(0o700)), 0)
        let lease = try ProjectRunLease.acquire(
            projectURL: fixture.projectURL,
            registryURL: fixture.registryURL
        )
        lease.release()
    }

    func testLeaseInvalidatesWhenNamedLockIsReplaced() throws {
        let fixture = try makeFixture(projectName: "LockReplacement.easysplatproj")
        defer { fixture.remove() }
        let lease = try ProjectRunLease.acquire(
            projectURL: fixture.projectURL,
            registryURL: fixture.registryURL
        )
        defer { lease.release() }
        let lockURL = try fixture.firstLockURL()
        let displacedURL = fixture.registryURL.appendingPathComponent("displaced.lock")
        try FileManager.default.moveItem(at: lockURL, to: displacedURL)
        try Data().write(to: lockURL)
        XCTAssertEqual(Darwin.chmod(lockURL.path, mode_t(0o600)), 0)

        assertLeaseError(.alreadyRunning) {
            try ProjectRunLease.acquire(
                projectURL: fixture.projectURL,
                registryURL: fixture.registryURL
            )
        }
        try runCrossProcessHelper(mode: "blocked", fixture: fixture)

        assertLeaseError(.unsafeProject) {
            try lease.revalidateProjectRoot()
        }
    }

    func testLeaseInvalidatesWhenRegistryDirectoryIsReplaced() throws {
        let fixture = try makeFixture(projectName: "RegistryReplacement.easysplatproj")
        defer { fixture.remove() }
        let lease = try ProjectRunLease.acquire(
            projectURL: fixture.projectURL,
            registryURL: fixture.registryURL
        )
        defer { lease.release() }
        let displacedURL = fixture.rootURL.appendingPathComponent(
            "displaced-registry",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: fixture.registryURL, to: displacedURL)
        try FileManager.default.createDirectory(
            at: fixture.registryURL,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(Darwin.chmod(fixture.registryURL.path, mode_t(0o700)), 0)

        assertLeaseError(.alreadyRunning) {
            try ProjectRunLease.acquire(
                projectURL: fixture.projectURL,
                registryURL: fixture.registryURL
            )
        }
        try runCrossProcessHelper(mode: "blocked", fixture: fixture)

        assertLeaseError(.unsafeProject) {
            try lease.revalidateProjectRoot()
        }
    }

    func testHostileSameUIDHierarchyReplacementInvalidatesOriginalLease() throws {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EasySplat-ProjectRunLeaseHostileParentTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let liveURL = rootURL.appendingPathComponent("live", isDirectory: true)
        let displacedURL = rootURL.appendingPathComponent("displaced", isDirectory: true)
        let projectURL = liveURL.appendingPathComponent("Project.easysplatproj", isDirectory: true)
        let registryURL = liveURL.appendingPathComponent("lease-registry", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let lease = try ProjectRunLease.acquire(
            projectURL: projectURL,
            registryURL: registryURL
        )
        defer { lease.release() }

        try FileManager.default.moveItem(at: liveURL, to: displacedURL)
        try FileManager.default.createDirectory(at: liveURL, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: false)

        // A hostile same-UID process can replace the project root, registry
        // parent, anchors, and registry together. Advisory locks cannot stop a
        // different process from opening those new inodes. The supported safety
        // property is that the original lease detects the detached hierarchy and
        // fails closed before any further mutation.
        assertLeaseError(.unsafeProject) {
            try lease.revalidateProjectRoot()
        }
    }

    func testLeaseRejectsSymlinkLockArtifact() throws {
        let fixture = try makeMaterializedFixture()
        defer { fixture.remove() }
        let lockURL = try fixture.firstLockURL()
        let externalURL = fixture.rootURL.appendingPathComponent("external.lock")
        try Data().write(to: externalURL)
        XCTAssertEqual(Darwin.chmod(externalURL.path, mode_t(0o600)), 0)
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createSymbolicLink(
            at: lockURL,
            withDestinationURL: externalURL
        )

        assertUnsafeLeaseWithoutPathDisclosure(fixture)
    }

    func testLeaseRejectsHardLinkedLockArtifact() throws {
        let fixture = try makeMaterializedFixture()
        defer { fixture.remove() }
        let lockURL = try fixture.firstLockURL()
        let aliasURL = fixture.rootURL.appendingPathComponent("linked-lock-alias")
        XCTAssertEqual(Darwin.link(lockURL.path, aliasURL.path), 0)

        assertUnsafeLeaseWithoutPathDisclosure(fixture)
    }

    func testLeaseRejectsFIFOLockArtifact() throws {
        let fixture = try makeMaterializedFixture()
        defer { fixture.remove() }
        let lockURL = try fixture.firstLockURL()
        try FileManager.default.removeItem(at: lockURL)
        XCTAssertEqual(Darwin.mkfifo(lockURL.path, mode_t(0o600)), 0)

        assertUnsafeLeaseWithoutPathDisclosure(fixture)
    }

    func testLeaseRejectsBroadLockArtifactMode() throws {
        let fixture = try makeMaterializedFixture()
        defer { fixture.remove() }
        let lockURL = try fixture.firstLockURL()
        XCTAssertEqual(Darwin.chmod(lockURL.path, mode_t(0o644)), 0)

        assertUnsafeLeaseWithoutPathDisclosure(fixture)
    }

    func testLeaseRejectsDirectoryLockArtifact() throws {
        let fixture = try makeMaterializedFixture()
        defer { fixture.remove() }
        let lockURL = try fixture.firstLockURL()
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createDirectory(
            at: lockURL,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(Darwin.chmod(lockURL.path, mode_t(0o700)), 0)

        assertUnsafeLeaseWithoutPathDisclosure(fixture)
    }

    func testLeaseRejectsLockArtifactContents() throws {
        let fixture = try makeMaterializedFixture()
        defer { fixture.remove() }
        let lockURL = try fixture.firstLockURL()
        try Data("project identity must never be stored here".utf8).write(to: lockURL)
        XCTAssertEqual(Darwin.chmod(lockURL.path, mode_t(0o600)), 0)

        assertUnsafeLeaseWithoutPathDisclosure(fixture)
    }

    func testLeaseRejectsSymlinkRegistryDirectory() throws {
        let fixture = try makeFixture(projectName: "RegistrySymlink.easysplatproj")
        defer { fixture.remove() }
        let externalRegistry = fixture.rootURL.appendingPathComponent(
            "external-registry",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: externalRegistry,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(Darwin.chmod(externalRegistry.path, mode_t(0o700)), 0)
        try FileManager.default.createSymbolicLink(
            at: fixture.registryURL,
            withDestinationURL: externalRegistry
        )

        assertUnsafeLeaseWithoutPathDisclosure(fixture)
    }

    func testLeaseRejectsBroadRegistryDirectoryMode() throws {
        let fixture = try makeFixture(projectName: "RegistryMode.easysplatproj")
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.registryURL,
            withIntermediateDirectories: false
        )
        XCTAssertEqual(Darwin.chmod(fixture.registryURL.path, mode_t(0o755)), 0)

        assertUnsafeLeaseWithoutPathDisclosure(fixture)
    }

    func testReleaseAllowsImmediateReacquisition() throws {
        let fixture = try makeFixture(projectName: "Release.easysplatproj")
        defer { fixture.remove() }

        let first = try ProjectRunLease.acquire(
            projectURL: fixture.projectURL,
            registryURL: fixture.registryURL
        )
        first.release()
        let second = try ProjectRunLease.acquire(
            projectURL: fixture.projectURL,
            registryURL: fixture.registryURL
        )
        second.release()
    }

    private func buildDescriptorExecProbe(in directoryURL: URL) throws -> URL {
        let sourceURL = directoryURL.appendingPathComponent("descriptor-exec-probe.c")
        let executableURL = directoryURL.appendingPathComponent("descriptor-exec-probe")
        let source = #"""
        #include <stdio.h>
        #include <stdlib.h>
        #include <sys/stat.h>
        #include <unistd.h>

        int main(int argc, char **argv) {
            for (int index = 1; index < argc; index++) {
                int descriptor = -1;
                unsigned long long device = 0;
                unsigned long long inode = 0;
                if (sscanf(argv[index], "%d:%llu:%llu", &descriptor, &device, &inode) != 3) {
                    return 2;
                }
                struct stat opened;
                if (fstat(descriptor, &opened) == 0
                    && (unsigned long long)opened.st_dev == device
                    && (unsigned long long)opened.st_ino == inode) {
                    return 1;
                }
            }
            return 0;
        }
        """#
        try Data(source.utf8).write(to: sourceURL, options: .atomic)

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["clang", sourceURL.path, "-o", executableURL.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        output.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        let diagnostics = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? "<non-UTF-8 compiler output>"
        guard process.terminationStatus == 0 else {
            XCTFail("Could not build descriptor exec probe: \(diagnostics)")
            throw CocoaError(.executableNotLoadable)
        }
        return executableURL
    }

    private func runExecProbe(
        helperURL: URL,
        arguments: [String]
    ) throws -> Int32 {
        let copiedArguments = ([helperURL.path] + arguments).map { strdup($0) }
        defer { copiedArguments.forEach { free($0) } }
        var vector = copiedArguments + [nil]
        var child = pid_t(0)
        let spawnStatus = vector.withUnsafeMutableBufferPointer { buffer in
            Darwin.posix_spawn(
                &child,
                helperURL.path,
                nil,
                nil,
                buffer.baseAddress!,
                environ
            )
        }
        guard spawnStatus == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: spawnStatus) ?? .EIO)
        }
        var status = Int32(0)
        while Darwin.waitpid(child, &status, 0) < 0 {
            if errno == EINTR { continue }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status & 0x7f == 0 else { return 255 }
        return (status >> 8) & 0xff
    }

    private func descriptorArgument(_ descriptor: Int32) throws -> String {
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return "\(descriptor):\(UInt64(opened.st_dev)):\(UInt64(opened.st_ino))"
    }

    private func makeMaterializedFixture() throws -> Fixture {
        let fixture = try makeFixture(projectName: "HostileLock.easysplatproj")
        let lease = try ProjectRunLease.acquire(
            projectURL: fixture.projectURL,
            registryURL: fixture.registryURL
        )
        lease.release()
        return fixture
    }

    private func runCrossProcessHelper(
        mode: String,
        fixture: Fixture,
        projectURL: URL? = nil
    ) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest",
            "-XCTest",
            "EasySplatCoreTests.ProjectRunLeaseTests/testCrossProcessAcquireHelperEntryPoint",
            Bundle(for: ProjectRunLeaseTests.self).bundleURL.path,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "EASYSPLAT_RUN_LEASE_HELPER_MODE": mode,
            "EASYSPLAT_RUN_LEASE_HELPER_PROJECT": (projectURL ?? fixture.projectURL).path,
            "EASYSPLAT_RUN_LEASE_HELPER_REGISTRY": fixture.registryURL.path,
        ]) { _, new in new }
        process.standardOutput = output
        process.standardError = output
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        try process.run()
        output.fileHandleForWriting.closeFile()
        guard terminated.wait(timeout: .now() + 20) == .success else {
            process.terminate()
            _ = terminated.wait(timeout: .now() + 5)
            throw CocoaError(.fileReadUnknown)
        }
        let diagnostics = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? "<non-UTF-8 child output>"
        XCTAssertEqual(
            process.terminationStatus,
            0,
            "Cross-process lease helper failed: \(diagnostics)"
        )
    }

    private func makeFixture(projectName: String) throws -> Fixture {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EasySplat-ProjectRunLeaseTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: false
        )
        let projectURL = rootURL.appendingPathComponent(
            projectName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: projectURL,
            withIntermediateDirectories: false
        )
        return Fixture(
            rootURL: rootURL,
            projectURL: projectURL,
            registryURL: rootURL.appendingPathComponent(
                "lease-registry",
                isDirectory: true
            )
        )
    }

    private func makeTmpAliasFixture(
        projectName: String
    ) throws -> TmpAliasFixture {
        let rootLeaf = "EasySplat-ProjectRunLeaseAliasTests-\(UUID().uuidString)"
        let canonicalRootURL = URL(
            fileURLWithPath: "/private/tmp",
            isDirectory: true
        ).appendingPathComponent(rootLeaf, isDirectory: true)
        let aliasRootURL = URL(
            fileURLWithPath: "/tmp",
            isDirectory: true
        ).appendingPathComponent(rootLeaf, isDirectory: true)
        try FileManager.default.createDirectory(
            at: canonicalRootURL,
            withIntermediateDirectories: false
        )
        guard try pathsNameSameDirectory(
            canonicalRootURL.path,
            aliasRootURL.path
        ) else {
            try? FileManager.default.removeItem(at: canonicalRootURL)
            throw XCTSkip("/tmp is not an alias of /private/tmp on this host.")
        }
        let fixture = TmpAliasFixture(
            canonicalRootURL: canonicalRootURL,
            canonicalProjectURL: canonicalRootURL.appendingPathComponent(
                projectName,
                isDirectory: true
            ),
            aliasProjectURL: aliasRootURL.appendingPathComponent(
                projectName,
                isDirectory: true
            ),
            registryURL: canonicalRootURL.appendingPathComponent(
                "lease-registry",
                isDirectory: true
            )
        )
        do {
            return try fixture.materialize()
        } catch {
            fixture.remove()
            throw error
        }
    }

    private func pathsNameSameDirectory(
        _ lhsPath: String,
        _ rhsPath: String
    ) throws -> Bool {
        var lhs = stat()
        guard Darwin.lstat(lhsPath, &lhs) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var rhs = stat()
        guard Darwin.lstat(rhsPath, &rhs) == 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return lhs.st_mode & S_IFMT == S_IFDIR
            && rhs.st_mode & S_IFMT == S_IFDIR
            && lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
    }

    private func descriptorPath(_ descriptor: Int32) throws -> String {
        let storageCount = (
            Int(MAXPATHLEN) + MemoryLayout<Darwin.flock>.stride - 1
        ) / MemoryLayout<Darwin.flock>.stride
        var storage = [Darwin.flock](
            repeating: Darwin.flock(),
            count: storageCount
        )
        _ = storage.withUnsafeMutableBytes { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
        }
        let status = storage.withUnsafeMutableBufferPointer { buffer in
            Darwin.fcntl(descriptor, F_GETPATH, buffer.baseAddress!)
        }
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let buffer = storage.withUnsafeBytes { bytes in
            Array(bytes.prefix(Int(MAXPATHLEN)))
        }
        guard let terminator = buffer.firstIndex(of: 0),
              let path = String(
                  bytes: buffer[..<terminator],
                  encoding: .utf8
              ) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return path
    }

    private func assertUnsafeLeaseWithoutPathDisclosure(
        _ fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let lease = try ProjectRunLease.acquire(
                projectURL: fixture.projectURL,
                registryURL: fixture.registryURL
            )
            lease.release()
            XCTFail("Expected an unsafe lease artifact rejection.", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? ProjectRunLeaseError,
                .unsafeProject,
                file: file,
                line: line
            )
            XCTAssertFalse(
                error.localizedDescription.contains(fixture.projectURL.path),
                file: file,
                line: line
            )
            XCTAssertFalse(
                error.localizedDescription.contains(fixture.projectURL.lastPathComponent),
                file: file,
                line: line
            )
        }
    }

    private func assertLeaseError<T>(
        _ expected: ProjectRunLeaseError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ operation: () throws -> T
    ) {
        do {
            _ = try operation()
            XCTFail("Expected project run lease failure.", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ProjectRunLeaseError, expected, file: file, line: line)
        }
    }
}

private struct Fixture {
    let rootURL: URL
    let projectURL: URL
    let registryURL: URL

    func registryEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: registryURL.path)
    }

    func firstLockURL() throws -> URL {
        guard let entry = try registryEntries().sorted().first else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return registryURL.appendingPathComponent(entry)
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private final class LockedTestBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private struct TmpAliasFixture {
    let canonicalRootURL: URL
    let canonicalProjectURL: URL
    let aliasProjectURL: URL
    let registryURL: URL

    func materialize() throws -> Self {
        try FileManager.default.createDirectory(
            at: canonicalProjectURL,
            withIntermediateDirectories: false
        )
        return self
    }

    func registryEntries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: registryURL.path)
    }

    func remove() {
        try? FileManager.default.removeItem(at: canonicalRootURL)
    }
}

private struct CaseSensitiveVolumeFixture {
    let rootURL: URL
    let imageURL: URL
    let mountURL: URL
    let registryURL: URL

    static func create() throws -> Self {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EasySplat-ProjectRunLeaseCaseTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let imageURL = rootURL.appendingPathComponent("case-sensitive.dmg")
        let mountURL = rootURL.appendingPathComponent("mount", isDirectory: true)
        let registryURL = rootURL.appendingPathComponent("lease-registry", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: false
            )
            try FileManager.default.createDirectory(
                at: mountURL,
                withIntermediateDirectories: false
            )
            try runHdiutil([
                "create",
                "-quiet",
                "-size", "16m",
                "-fs", "Case-sensitive APFS",
                "-volname", "EasySplatLeaseCase",
                imageURL.path,
            ])
            try runHdiutil([
                "attach",
                "-quiet",
                "-nobrowse",
                "-mountpoint", mountURL.path,
                imageURL.path,
            ])
            return Self(
                rootURL: rootURL,
                imageURL: imageURL,
                mountURL: mountURL,
                registryURL: registryURL
            )
        } catch {
            try? runHdiutil(["detach", "-quiet", mountURL.path])
            try? FileManager.default.removeItem(at: rootURL)
            throw error
        }
    }

    func remove() {
        try? Self.runHdiutil(["detach", "-quiet", mountURL.path])
        try? FileManager.default.removeItem(at: rootURL)
    }

    private static func runHdiutil(_ arguments: [String]) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        output.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let diagnostics = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "<non-UTF-8 hdiutil output>"
            throw NSError(
                domain: "ProjectRunLeaseTests.CaseSensitiveVolume",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: diagnostics]
            )
        }
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}
#endif
