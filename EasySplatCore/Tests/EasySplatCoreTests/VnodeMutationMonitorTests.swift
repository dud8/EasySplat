import Darwin
import Foundation
import XCTest
@testable import EasySplatCore

final class VnodeMutationMonitorTests: XCTestCase {
    func testPollReportsWriteMutationForBorrowedDescriptor() throws {
        let fixture = try makeFileFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let flags = try observeMutation(of: fixture.file) {
            let writer = try FileHandle(forWritingTo: fixture.file)
            try writer.write(contentsOf: Data("mutation".utf8))
            try writer.synchronize()
            try writer.close()
        }

        XCTAssertTrue(flags.contains(.write), "Observed flags: \(flags)")
    }

    func testPollReportsExtendMutation() throws {
        let fixture = try makeFileFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let flags = try observeMutation(of: fixture.file) {
            let descriptor = Darwin.open(fixture.file.path, O_WRONLY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { if descriptor >= 0 { Darwin.close(descriptor) } }
            XCTAssertEqual(ftruncate(descriptor, 4_096), 0)
        }

        XCTAssertTrue(flags.contains(.extend), "Observed flags: \(flags)")
    }

    func testPollReportsAttributeMutation() throws {
        let fixture = try makeFileFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let flags = try observeMutation(of: fixture.file) {
            XCTAssertEqual(chmod(fixture.file.path, S_IRUSR), 0)
        }

        XCTAssertTrue(flags.contains(.attribute), "Observed flags: \(flags)")
    }

    func testPollReportsRenameMutation() throws {
        let fixture = try makeFileFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let renamed = fixture.directory.appendingPathComponent("renamed.mov")

        let flags = try observeMutation(of: fixture.file) {
            XCTAssertEqual(rename(fixture.file.path, renamed.path), 0)
        }

        XCTAssertTrue(flags.contains(.rename), "Observed flags: \(flags)")
    }

    func testPollReportsDeleteMutation() throws {
        let fixture = try makeFileFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let flags = try observeMutation(of: fixture.file) {
            XCTAssertEqual(unlink(fixture.file.path), 0)
        }

        XCTAssertTrue(flags.contains(.delete), "Observed flags: \(flags)")
    }

    func testPollReportsLinkMutation() throws {
        let fixture = try makeFileFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let hardLink = fixture.directory.appendingPathComponent("hard-link.mov")

        let flags = try observeMutation(of: fixture.file) {
            XCTAssertEqual(link(fixture.file.path, hardLink.path), 0)
        }

        XCTAssertTrue(flags.contains(.link), "Observed flags: \(flags)")
    }

    func testDuplicatedOwnershipSurvivesCallerClosingOriginalDescriptor() throws {
        let fixture = try makeFileFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let descriptor = Darwin.open(fixture.file.path, O_EVTONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)

        let monitor = try VnodeMutationMonitor(watches: [
            .init(descriptor: descriptor, label: "video.mov", ownership: .duplicated),
        ])
        XCTAssertEqual(Darwin.close(descriptor), 0)
        defer { monitor.close() }

        let writer = try FileHandle(forWritingTo: fixture.file)
        try writer.write(contentsOf: Data("mutation".utf8))
        try writer.synchronize()
        try writer.close()

        XCTAssertTrue(try mutation(for: "video.mov", in: monitor.poll()).flags.contains(.write))
    }

    func testCoalescedFlagsAndLaterFailureRemainSticky() throws {
        let kernel = KernelStub(
            pollResults: [
                .success([.init(
                    descriptor: 17,
                    eventFlags: 0,
                    vnodeFlags: UInt32(NOTE_WRITE | NOTE_EXTEND)
                )]),
                .failure(errno: EIO),
                .success([]),
            ]
        )
        let monitor = try VnodeMutationMonitor(
            watches: [.init(descriptor: 17, label: "video.mov", ownership: .borrowed)],
            systemCalls: kernel.systemCalls
        )
        defer { monitor.close() }

        let first = monitor.poll()
        XCTAssertEqual(try mutation(for: "video.mov", in: first).flags, [.write, .extend])
        XCTAssertNil(first.failure)

        let failed = monitor.poll()
        XCTAssertEqual(failed.failure, .pollingFailed(errno: EIO))
        XCTAssertEqual(try mutation(for: "video.mov", in: failed).flags, [.write, .extend])

        let later = monitor.poll()
        XCTAssertEqual(later, failed)
        XCTAssertFalse(later.isTrustworthy)
    }

    func testAcknowledgingExpectedSnapshotClearsOnlyObservedGeneration() throws {
        let kernel = KernelStub(pollResults: [
            .success([.init(
                descriptor: 17,
                eventFlags: 0,
                vnodeFlags: UInt32(NOTE_WRITE | NOTE_LINK)
            )]),
            .success([.init(
                descriptor: 17,
                eventFlags: 0,
                vnodeFlags: UInt32(NOTE_RENAME)
            )]),
        ])
        let monitor = try VnodeMutationMonitor(
            watches: [.init(descriptor: 17, label: "library", ownership: .borrowed)],
            systemCalls: kernel.systemCalls
        )
        defer { monitor.close() }

        let expected = VnodeMutationMonitor.Snapshot(
            mutations: [.init(label: "library", flags: [.write, .link])],
            failure: nil
        )
        XCTAssertTrue(monitor.acknowledgeCurrentSnapshot { $0 == expected })
        XCTAssertEqual(
            monitor.poll().mutations,
            [.init(label: "library", flags: [.rename])]
        )
    }

    func testRejectedAcknowledgementKeepsObservedMutationSticky() throws {
        let kernel = KernelStub(pollResults: [
            .success([.init(
                descriptor: 17,
                eventFlags: 0,
                vnodeFlags: UInt32(NOTE_DELETE)
            )]),
            .success([]),
        ])
        let monitor = try VnodeMutationMonitor(
            watches: [.init(descriptor: 17, label: "library", ownership: .borrowed)],
            systemCalls: kernel.systemCalls
        )
        defer { monitor.close() }

        XCTAssertFalse(monitor.acknowledgeCurrentSnapshot { _ in false })
        XCTAssertEqual(
            monitor.poll().mutations,
            [.init(label: "library", flags: [.delete])]
        )
    }

    func testRevokeEventFailsClosedAndReportsMutation() throws {
        let kernel = KernelStub(pollResults: [
            .success([.init(
                descriptor: 17,
                eventFlags: 0,
                vnodeFlags: UInt32(NOTE_REVOKE)
            )]),
        ])
        let monitor = try VnodeMutationMonitor(
            watches: [.init(descriptor: 17, label: "video.mov", ownership: .borrowed)],
            systemCalls: kernel.systemCalls
        )
        defer { monitor.close() }

        let snapshot = monitor.poll()

        XCTAssertEqual(try mutation(for: "video.mov", in: snapshot).flags, [.revoke])
        XCTAssertNil(snapshot.failure)
        XCTAssertFalse(snapshot.isTrustworthy)
    }

    func testKernelErrorAndEOFEventsFailClosed() throws {
        let errorKernel = KernelStub(pollResults: [
            .success([.init(
                descriptor: 17,
                eventFlags: UInt16(EV_ERROR),
                vnodeFlags: 0,
                data: Int64(EBADF)
            )]),
        ])
        let errorMonitor = try VnodeMutationMonitor(
            watches: [.init(descriptor: 17, label: "error.mov", ownership: .borrowed)],
            systemCalls: errorKernel.systemCalls
        )
        defer { errorMonitor.close() }
        XCTAssertEqual(errorMonitor.poll().failure, .eventError(label: "error.mov", errno: EBADF))

        let eofKernel = KernelStub(pollResults: [
            .success([.init(
                descriptor: 23,
                eventFlags: UInt16(EV_EOF),
                vnodeFlags: 0
            )]),
        ])
        let eofMonitor = try VnodeMutationMonitor(
            watches: [.init(descriptor: 23, label: "eof.mov", ownership: .borrowed)],
            systemCalls: eofKernel.systemCalls
        )
        defer { eofMonitor.close() }
        XCTAssertEqual(eofMonitor.poll().failure, .endOfFile(label: "eof.mov"))
    }

    func testRegistrationAndPollingRetryEINTR() throws {
        let kernel = KernelStub(
            registrationResults: [.interrupted, .success(())],
            pollResults: [.interrupted, .success([])]
        )
        let monitor = try VnodeMutationMonitor(
            watches: [.init(descriptor: 17, label: "video.mov", ownership: .borrowed)],
            systemCalls: kernel.systemCalls
        )
        defer { monitor.close() }

        XCTAssertEqual(monitor.poll(), .init(mutations: [], failure: nil))
        XCTAssertEqual(kernel.registrationCallCount, 2)
        XCTAssertEqual(kernel.pollCallCount, 2)
    }

    func testRegistrationArmsEveryRequiredVnodeFlag() throws {
        let kernel = KernelStub()
        let monitor = try VnodeMutationMonitor(
            watches: [.init(descriptor: 17, label: "video.mov", ownership: .borrowed)],
            systemCalls: kernel.systemCalls
        )
        defer { monitor.close() }

        XCTAssertEqual(kernel.registeredVnodeFlags, [UInt32(
            NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_RENAME |
                NOTE_DELETE | NOTE_LINK | NOTE_REVOKE
        )])
    }

    func testInvalidDescriptorIsAnExplicitSetupFailure() {
        XCTAssertThrowsError(try VnodeMutationMonitor(watches: [
            .init(descriptor: -1, label: "invalid.mov", ownership: .borrowed),
        ])) { error in
            XCTAssertEqual(
                error as? VnodeMutationMonitor.Failure,
                .invalidDescriptor(label: "invalid.mov")
            )
        }
    }

    func testClosedDescriptorFailsRegistrationExplicitly() throws {
        let fixture = try makeFileFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let descriptor = Darwin.open(fixture.file.path, O_EVTONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(Darwin.close(descriptor), 0)

        XCTAssertThrowsError(try VnodeMutationMonitor(watches: [
            .init(descriptor: descriptor, label: "closed.mov", ownership: .borrowed),
        ])) { error in
            guard case let .registrationFailed(label, errorNumber) =
                error as? VnodeMutationMonitor.Failure else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(label, "closed.mov")
            XCTAssertTrue(
                errorNumber == EBADF || errorNumber == EINVAL,
                "A closed descriptor may remain invalid or be reused by kqueue itself"
            )
        }
    }

    func testEmptyWatchListAndQueueCreationFailureAreExplicit() {
        XCTAssertThrowsError(try VnodeMutationMonitor(watches: [])) { error in
            XCTAssertEqual(error as? VnodeMutationMonitor.Failure, .noWatches)
        }

        let kernel = KernelStub(createQueueResult: .failure(errno: EMFILE))
        XCTAssertThrowsError(try VnodeMutationMonitor(
            watches: [.init(descriptor: 17, label: "video.mov", ownership: .borrowed)],
            systemCalls: kernel.systemCalls
        )) { error in
            XCTAssertEqual(
                error as? VnodeMutationMonitor.Failure,
                .queueCreationFailed(errno: EMFILE)
            )
        }
        XCTAssertTrue(kernel.closedDescriptors.isEmpty)
    }

    func testRegistrationFailureClosesQueueAndOwnedDuplicateExactlyOnce() {
        let kernel = KernelStub(
            duplicateResults: [.success(41)],
            registrationResults: [.failure(errno: EBADF)]
        )

        XCTAssertThrowsError(try VnodeMutationMonitor(
            watches: [.init(descriptor: 17, label: "video.mov", ownership: .duplicated)],
            systemCalls: kernel.systemCalls
        )) { error in
            XCTAssertEqual(
                error as? VnodeMutationMonitor.Failure,
                .registrationFailed(label: "video.mov", errno: EBADF)
            )
        }
        XCTAssertEqual(kernel.closedDescriptors.sorted(), [41, KernelStub.queueDescriptor])
    }

    func testCloseIsIdempotentAndNeverClosesBorrowedDescriptors() throws {
        let kernel = KernelStub(duplicateResults: [.success(41)])
        let monitor = try VnodeMutationMonitor(
            watches: [
                .init(descriptor: 17, label: "borrowed.mov", ownership: .borrowed),
                .init(descriptor: 23, label: "owned.mov", ownership: .duplicated),
            ],
            systemCalls: kernel.systemCalls
        )

        monitor.close()
        monitor.close()

        XCTAssertEqual(kernel.closedDescriptors.sorted(), [41, KernelStub.queueDescriptor])
        XCTAssertFalse(kernel.closedDescriptors.contains(17))
        XCTAssertFalse(kernel.closedDescriptors.contains(23))
        XCTAssertEqual(monitor.poll().failure, .closed)
    }

    private func observeMutation(
        of file: URL,
        action: () throws -> Void
    ) throws -> VnodeMutationMonitor.MutationFlags {
        let descriptor = Darwin.open(file.path, O_EVTONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }
        let monitor = try VnodeMutationMonitor(watches: [
            .init(descriptor: descriptor, label: "video.mov", ownership: .borrowed),
        ])
        defer { monitor.close() }

        try action()
        return try mutation(for: "video.mov", in: monitor.poll()).flags
    }

    private func mutation(
        for label: String,
        in snapshot: VnodeMutationMonitor.Snapshot
    ) throws -> VnodeMutationMonitor.Mutation {
        try XCTUnwrap(snapshot.mutations.first { $0.label == label })
    }

    private func makeFileFixture() throws -> (directory: URL, file: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VnodeMutationMonitorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("video.mov")
        try Data("original".utf8).write(to: file, options: .withoutOverwriting)
        return (directory, file)
    }
}

private final class KernelStub: @unchecked Sendable {
    static let queueDescriptor: Int32 = 900

    private let lock = NSLock()
    private let createQueueResult: VnodeMutationMonitor.SystemCallResult<Int32>
    private var duplicateResults: [VnodeMutationMonitor.SystemCallResult<Int32>]
    private var registrationResults: [VnodeMutationMonitor.SystemCallResult<Void>]
    private var pollResults: [VnodeMutationMonitor.SystemCallResult<[VnodeMutationMonitor.KernelEvent]>]
    private var registrationCalls = 0
    private var pollCalls = 0
    private var registrationFlags: [UInt32] = []
    private var closed: [Int32] = []

    init(
        createQueueResult: VnodeMutationMonitor.SystemCallResult<Int32> = .success(queueDescriptor),
        duplicateResults: [VnodeMutationMonitor.SystemCallResult<Int32>] = [],
        registrationResults: [VnodeMutationMonitor.SystemCallResult<Void>] = [],
        pollResults: [VnodeMutationMonitor.SystemCallResult<[VnodeMutationMonitor.KernelEvent]>] = []
    ) {
        self.createQueueResult = createQueueResult
        self.duplicateResults = duplicateResults
        self.registrationResults = registrationResults
        self.pollResults = pollResults
    }

    var registrationCallCount: Int { lock.withLock { registrationCalls } }
    var pollCallCount: Int { lock.withLock { pollCalls } }
    var registeredVnodeFlags: [UInt32] { lock.withLock { registrationFlags } }
    var closedDescriptors: [Int32] { lock.withLock { closed } }

    var systemCalls: VnodeMutationMonitor.SystemCalls {
        .init(
            createQueue: { [self] in createQueueResult },
            duplicate: { [self] _ in
                lock.withLock {
                    duplicateResults.isEmpty ? .failure(errno: EMFILE) : duplicateResults.removeFirst()
                }
            },
            register: { [self] _, _, vnodeFlags in
                lock.withLock {
                    registrationCalls += 1
                    registrationFlags.append(vnodeFlags)
                    return registrationResults.isEmpty
                        ? .success(())
                        : registrationResults.removeFirst()
                }
            },
            poll: { [self] _, _ in
                lock.withLock {
                    pollCalls += 1
                    return pollResults.isEmpty ? .success([]) : pollResults.removeFirst()
                }
            },
            close: { [self] descriptor in
                lock.withLock { closed.append(descriptor) }
            }
        )
    }
}
