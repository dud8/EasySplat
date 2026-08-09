import Darwin
import Foundation

private func easysplatKevent(
    _ queue: Int32,
    _ changes: UnsafePointer<kevent>?,
    _ changeCount: Int32,
    _ events: UnsafeMutablePointer<kevent>?,
    _ eventCount: Int32,
    _ timeout: UnsafePointer<timespec>?
) -> Int32 {
    let call: @convention(c) (
        Int32,
        UnsafePointer<kevent>?,
        Int32,
        UnsafeMutablePointer<kevent>?,
        Int32,
        UnsafePointer<timespec>?
    ) -> Int32 = kevent
    return call(queue, changes, changeCount, events, eventCount, timeout)
}

/// Synchronously detects vnode mutations to already-open file descriptors.
///
/// A snapshot is deliberately sticky: once any watched vnode mutates or any
/// monitoring failure occurs, no later poll can make the monitor trustworthy
/// again. This type does not validate paths, metadata, or file identity.
final class VnodeMutationMonitor: @unchecked Sendable {
    enum DescriptorOwnership: Equatable, Sendable {
        /// The caller retains ownership and must keep the descriptor open until
        /// the monitor is closed or deinitialized.
        case borrowed

        /// The monitor creates and owns a close-on-exec duplicate.
        case duplicated
    }

    struct Watch: Equatable, Sendable {
        let descriptor: Int32
        let label: String
        let ownership: DescriptorOwnership
    }

    struct MutationFlags: OptionSet, Equatable, Sendable {
        let rawValue: UInt32

        static let write = MutationFlags(rawValue: UInt32(NOTE_WRITE))
        static let extend = MutationFlags(rawValue: UInt32(NOTE_EXTEND))
        static let attribute = MutationFlags(rawValue: UInt32(NOTE_ATTRIB))
        static let rename = MutationFlags(rawValue: UInt32(NOTE_RENAME))
        static let delete = MutationFlags(rawValue: UInt32(NOTE_DELETE))
        static let link = MutationFlags(rawValue: UInt32(NOTE_LINK))
        static let revoke = MutationFlags(rawValue: UInt32(NOTE_REVOKE))

        static let all: MutationFlags = [
            .write, .extend, .attribute, .rename, .delete, .link, .revoke,
        ]
    }

    struct Mutation: Equatable, Sendable {
        let label: String
        let flags: MutationFlags
    }

    enum Failure: Error, Equatable, Sendable {
        case unsupportedPlatform
        case noWatches
        case invalidDescriptor(label: String)
        case duplicateLabel(String)
        case duplicateDescriptor(label: String)
        case queueCreationFailed(errno: Int32)
        case duplicationFailed(label: String, errno: Int32)
        case registrationFailed(label: String, errno: Int32)
        case pollingFailed(errno: Int32)
        case eventError(label: String, errno: Int32)
        case endOfFile(label: String)
        case unknownDescriptor(Int32)
        case closed
    }

    struct Snapshot: Equatable, Sendable {
        let mutations: [Mutation]
        let failure: Failure?

        var isTrustworthy: Bool {
            mutations.isEmpty && failure == nil
        }
    }

    enum SystemCallResult<Value: Sendable>: Sendable {
        case success(Value)
        case interrupted
        case failure(errno: Int32)
    }

    struct KernelEvent: Equatable, Sendable {
        let descriptor: Int32
        let eventFlags: UInt16
        let vnodeFlags: UInt32
        let data: Int64

        init(
            descriptor: Int32,
            eventFlags: UInt16,
            vnodeFlags: UInt32,
            data: Int64 = 0
        ) {
            self.descriptor = descriptor
            self.eventFlags = eventFlags
            self.vnodeFlags = vnodeFlags
            self.data = data
        }
    }

    struct SystemCalls: Sendable {
        let createQueue: @Sendable () -> SystemCallResult<Int32>
        let duplicate: @Sendable (Int32) -> SystemCallResult<Int32>
        let register: @Sendable (Int32, Int32, UInt32) -> SystemCallResult<Void>
        let poll: @Sendable (Int32, Int) -> SystemCallResult<[KernelEvent]>
        let close: @Sendable (Int32) -> Void
    }

    private struct ResolvedWatch: Sendable {
        let descriptor: Int32
        let label: String
    }

    private let lock = NSLock()
    private let systemCalls: SystemCalls
    private let watches: [ResolvedWatch]
    private let labelsByDescriptor: [Int32: String]
    private var queueDescriptor: Int32
    private var ownedDescriptors: [Int32]
    private var mutationsByDescriptor: [Int32: MutationFlags] = [:]
    private var stickyFailure: Failure?

    convenience init(watches: [Watch]) throws {
#if os(macOS)
        try self.init(watches: watches, systemCalls: .production)
#else
        throw Failure.unsupportedPlatform
#endif
    }

    init(watches requestedWatches: [Watch], systemCalls: SystemCalls) throws {
        guard !requestedWatches.isEmpty else { throw Failure.noWatches }
        var labels = Set<String>()
        for watch in requestedWatches {
            guard watch.descriptor >= 0 else {
                throw Failure.invalidDescriptor(label: watch.label)
            }
            guard labels.insert(watch.label).inserted else {
                throw Failure.duplicateLabel(watch.label)
            }
        }

        let queueDescriptor: Int32
        switch systemCalls.createQueue() {
        case let .success(created):
            queueDescriptor = created
        case .interrupted:
            throw Failure.queueCreationFailed(errno: EINTR)
        case let .failure(errorNumber):
            throw Failure.queueCreationFailed(errno: errorNumber)
        }
        guard queueDescriptor >= 0 else {
            throw Failure.queueCreationFailed(errno: EBADF)
        }

        var resolved: [ResolvedWatch] = []
        var owned: [Int32] = []
        var registeredDescriptors = Set<Int32>()
        do {
            for watch in requestedWatches {
                let descriptor: Int32
                switch watch.ownership {
                case .borrowed:
                    descriptor = watch.descriptor
                case .duplicated:
                    descriptor = try Self.duplicate(
                        watch.descriptor,
                        label: watch.label,
                        using: systemCalls
                    )
                    owned.append(descriptor)
                }

                guard registeredDescriptors.insert(descriptor).inserted else {
                    throw Failure.duplicateDescriptor(label: watch.label)
                }
                try Self.register(
                    descriptor,
                    label: watch.label,
                    queueDescriptor: queueDescriptor,
                    using: systemCalls
                )
                resolved.append(.init(
                    descriptor: descriptor,
                    label: watch.label
                ))
            }
        } catch {
            for descriptor in owned.reversed() {
                systemCalls.close(descriptor)
            }
            systemCalls.close(queueDescriptor)
            throw error
        }

        self.systemCalls = systemCalls
        self.watches = resolved
        self.labelsByDescriptor = Dictionary(
            uniqueKeysWithValues: resolved.map { ($0.descriptor, $0.label) }
        )
        self.queueDescriptor = queueDescriptor
        self.ownedDescriptors = owned
    }

    deinit {
        close()
    }

    /// Performs a zero-timeout poll and returns all mutations and the first
    /// failure observed over the monitor's entire lifetime.
    func poll() -> Snapshot {
        lock.withLock {
            pollLocked()
            return snapshot()
        }
    }

    /// Acknowledges one explicitly expected mutation generation without
    /// disarming the kqueue. Events arriving after this zero-timeout poll remain
    /// queued and will be reported by the next poll.
    func acknowledgeCurrentSnapshot(
        where isExpected: (Snapshot) -> Bool
    ) -> Bool {
        lock.withLock {
            pollLocked()
            let current = snapshot()
            guard isExpected(current) else { return false }
            mutationsByDescriptor.removeAll(keepingCapacity: true)
            return true
        }
    }

    /// Releases the kqueue and monitor-owned duplicates exactly once. Borrowed
    /// descriptors are never closed.
    func close() {
        let descriptors = lock.withLock { () -> (queue: Int32, owned: [Int32])? in
            guard queueDescriptor >= 0 else { return nil }
            let descriptors = (queueDescriptor, ownedDescriptors)
            queueDescriptor = -1
            ownedDescriptors.removeAll(keepingCapacity: false)
            return descriptors
        }
        guard let descriptors else { return }
        for descriptor in descriptors.owned.reversed() {
            systemCalls.close(descriptor)
        }
        systemCalls.close(descriptors.queue)
    }

    private func record(_ event: KernelEvent) {
        guard let label = labelsByDescriptor[event.descriptor] else {
            recordFailure(.unknownDescriptor(event.descriptor))
            return
        }

        let mutationFlags = MutationFlags(rawValue: event.vnodeFlags).intersection(.all)
        if !mutationFlags.isEmpty {
            mutationsByDescriptor[event.descriptor, default: []].formUnion(mutationFlags)
        }

        if event.eventFlags & UInt16(EV_ERROR) != 0 {
            let errorNumber = event.data > 0 ? Int32(clamping: event.data) : EIO
            recordFailure(.eventError(label: label, errno: errorNumber))
        } else if event.eventFlags & UInt16(EV_EOF) != 0 {
            recordFailure(.endOfFile(label: label))
        }
    }

    private func pollLocked() {
        guard queueDescriptor >= 0 else {
            recordFailure(.closed)
            return
        }

        let result: SystemCallResult<[KernelEvent]>
        while true {
            let attempt = systemCalls.poll(queueDescriptor, max(watches.count, 1))
            if case .interrupted = attempt { continue }
            result = attempt
            break
        }

        switch result {
        case let .success(events):
            for event in events {
                record(event)
            }
        case .interrupted:
            preconditionFailure("EINTR must be retried")
        case let .failure(errorNumber):
            recordFailure(.pollingFailed(errno: errorNumber))
        }
    }

    private func recordFailure(_ failure: Failure) {
        if stickyFailure == nil {
            stickyFailure = failure
        }
    }

    private func snapshot() -> Snapshot {
        Snapshot(
            mutations: watches.compactMap { watch in
                mutationsByDescriptor[watch.descriptor].map {
                    Mutation(label: watch.label, flags: $0)
                }
            },
            failure: stickyFailure
        )
    }

    private static func duplicate(
        _ descriptor: Int32,
        label: String,
        using systemCalls: SystemCalls
    ) throws -> Int32 {
        while true {
            switch systemCalls.duplicate(descriptor) {
            case let .success(duplicate):
                guard duplicate >= 0 else {
                    throw Failure.duplicationFailed(label: label, errno: EBADF)
                }
                return duplicate
            case .interrupted:
                continue
            case let .failure(errorNumber):
                throw Failure.duplicationFailed(label: label, errno: errorNumber)
            }
        }
    }

    private static func register(
        _ descriptor: Int32,
        label: String,
        queueDescriptor: Int32,
        using systemCalls: SystemCalls
    ) throws {
        while true {
            switch systemCalls.register(
                queueDescriptor,
                descriptor,
                MutationFlags.all.rawValue
            ) {
            case .success:
                return
            case .interrupted:
                continue
            case let .failure(errorNumber):
                throw Failure.registrationFailed(label: label, errno: errorNumber)
            }
        }
    }
}

private extension VnodeMutationMonitor.SystemCalls {
    static let production = VnodeMutationMonitor.SystemCalls(
        createQueue: {
            let descriptor = kqueue()
            guard descriptor >= 0 else { return .failure(errno: errno) }
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
                let errorNumber = errno
                Darwin.close(descriptor)
                return .failure(errno: errorNumber)
            }
            return .success(descriptor)
        },
        duplicate: { descriptor in
            let duplicated = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            if duplicated >= 0 { return .success(duplicated) }
            if errno == EINTR { return .interrupted }
            return .failure(errno: errno)
        },
        register: { queue, descriptor, vnodeFlags in
            var change = kevent(
                ident: UInt(descriptor),
                filter: Int16(EVFILT_VNODE),
                flags: UInt16(EV_ADD | EV_ENABLE | EV_CLEAR),
                fflags: vnodeFlags,
                data: 0,
                udata: nil
            )
            let result = easysplatKevent(queue, &change, 1, nil, 0, nil)
            if result == 0 { return .success(()) }
            if errno == EINTR { return .interrupted }
            return .failure(errno: errno)
        },
        poll: { queue, maximumEventCount in
            var events = Array(repeating: kevent(), count: maximumEventCount)
            var timeout = timespec(tv_sec: 0, tv_nsec: 0)
            let count = events.withUnsafeMutableBufferPointer { buffer in
                easysplatKevent(
                    queue,
                    nil,
                    0,
                    buffer.baseAddress,
                    Int32(buffer.count),
                    &timeout
                )
            }
            if count < 0 {
                if errno == EINTR { return .interrupted }
                return .failure(errno: errno)
            }
            return .success(events.prefix(Int(count)).map {
                VnodeMutationMonitor.KernelEvent(
                    descriptor: Int32(clamping: $0.ident),
                    eventFlags: $0.flags,
                    vnodeFlags: $0.fflags,
                    data: Int64($0.data)
                )
            })
        },
        close: { descriptor in
            _ = Darwin.close(descriptor)
        }
    )
}
