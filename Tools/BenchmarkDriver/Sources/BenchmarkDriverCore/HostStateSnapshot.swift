import Darwin
import Foundation
import IOKit.ps

public struct HostStateSnapshot: Codable, Equatable, Sendable {
    public struct CPUTicks: Codable, Equatable, Sendable {
        public let user: UInt64
        public let system: UInt64
        public let idle: UInt64
        public let nice: UInt64
    }

    public enum ThermalState: String, Codable, Sendable {
        case nominal
        case fair
        case serious
        case critical
    }

    public enum PowerSource: String, Codable, Sendable {
        case acPower = "ac_power"
        case batteryPower = "battery_power"
        case upsPower = "ups_power"
    }

    public let cpuTicks: CPUTicks
    public let vmPageouts: UInt64
    public let vmSwapouts: UInt64
    public let thermalState: ThermalState
    public let lowPowerMode: Bool
    public let powerSource: PowerSource

    private enum CodingKeys: String, CodingKey {
        case cpuTicks = "cpu_ticks"
        case vmPageouts = "vm_pageouts"
        case vmSwapouts = "vm_swapouts"
        case thermalState = "thermal_state"
        case lowPowerMode = "low_power_mode"
        case powerSource = "power_source"
    }

    public static func capture() throws -> Self {
        let processInfo = ProcessInfo.processInfo
        let vmStatistics = try captureVMStatistics()
        return Self(
            cpuTicks: try captureCPUTicks(),
            vmPageouts: vmStatistics.pageouts,
            vmSwapouts: vmStatistics.swapouts,
            thermalState: try thermalState(processInfo.thermalState),
            lowPowerMode: processInfo.isLowPowerModeEnabled,
            powerSource: try capturePowerSource()
        )
    }

    private static func captureCPUTicks() throws -> CPUTicks {
        var statistics = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            throw HostStateSnapshotError.hostStatistics(status)
        }
        return CPUTicks(
            user: UInt64(statistics.cpu_ticks.0),
            system: UInt64(statistics.cpu_ticks.1),
            idle: UInt64(statistics.cpu_ticks.2),
            nice: UInt64(statistics.cpu_ticks.3)
        )
    }

    private static func captureVMStatistics() throws -> (pageouts: UInt64, swapouts: UInt64) {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            throw HostStateSnapshotError.hostStatistics(status)
        }
        return (statistics.pageouts, statistics.swapouts)
    }

    private static func thermalState(
        _ state: ProcessInfo.ThermalState
    ) throws -> ThermalState {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: throw HostStateSnapshotError.unsupportedThermalState
        }
    }

    private static func capturePowerSource() throws -> PowerSource {
        guard
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
        else {
            throw HostStateSnapshotError.powerSourceUnavailable
        }
        let rawValue = source as String
        switch rawValue {
        case kIOPMACPowerKey: return .acPower
        case kIOPMBatteryPowerKey: return .batteryPower
        case kIOPMUPSPowerKey: return .upsPower
        default: throw HostStateSnapshotError.powerSourceUnavailable
        }
    }

}

public struct HostStateSample: Codable, Equatable, Sendable {
    public let monotonicSeconds: TimeInterval
    public let state: HostStateSnapshot

    private enum CodingKeys: String, CodingKey {
        case monotonicSeconds = "monotonic_seconds"
        case state
    }
}

public struct HostStateChangeEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case thermalState = "thermal_state"
        case lowPowerMode = "low_power_mode"
        case powerSource = "power_source"
    }

    public let monotonicSeconds: TimeInterval
    public let kind: Kind

    private enum CodingKeys: String, CodingKey {
        case monotonicSeconds = "monotonic_seconds"
        case kind
    }
}

public struct HostStateMonitorReceipt: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let monotonicClock: String
    public let sampleIntervalSeconds: TimeInterval
    public let samples: [HostStateSample]
    public let events: [HostStateChangeEvent]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case monotonicClock = "monotonic_clock"
        case sampleIntervalSeconds = "sample_interval_seconds"
        case samples
        case events
    }
}

public enum HostStateMonitor {
    public static func capture(
        sampleIntervalSeconds: TimeInterval,
        readyFileDescriptor: Int32,
        stopFileDescriptor: Int32,
        maximumSampleCount: Int = 100_000
    ) throws -> HostStateMonitorReceipt {
        try capture(
            sampleIntervalSeconds: sampleIntervalSeconds,
            readyFileDescriptor: readyFileDescriptor,
            stopFileDescriptor: stopFileDescriptor,
            maximumSampleCount: maximumSampleCount,
            notificationCenter: .default,
            notificationQueue: nil,
            observePowerSourceChanges: true,
            snapshotProvider: HostStateSnapshot.capture
        )
    }

    static func captureForTesting(
        sampleIntervalSeconds: TimeInterval,
        readyFileDescriptor: Int32,
        stopFileDescriptor: Int32,
        maximumSampleCount: Int = 100_000,
        notificationCenter: NotificationCenter,
        notificationQueue: OperationQueue? = nil,
        snapshotProvider: @escaping @Sendable () throws -> HostStateSnapshot
    ) throws -> HostStateMonitorReceipt {
        try capture(
            sampleIntervalSeconds: sampleIntervalSeconds,
            readyFileDescriptor: readyFileDescriptor,
            stopFileDescriptor: stopFileDescriptor,
            maximumSampleCount: maximumSampleCount,
            notificationCenter: notificationCenter,
            notificationQueue: notificationQueue,
            observePowerSourceChanges: false,
            snapshotProvider: snapshotProvider
        )
    }

    private static func capture(
        sampleIntervalSeconds: TimeInterval,
        readyFileDescriptor: Int32,
        stopFileDescriptor: Int32,
        maximumSampleCount: Int,
        notificationCenter: NotificationCenter,
        notificationQueue: OperationQueue?,
        observePowerSourceChanges: Bool,
        snapshotProvider: @escaping @Sendable () throws -> HostStateSnapshot
    ) throws -> HostStateMonitorReceipt {
        guard sampleIntervalSeconds >= 0.05, sampleIntervalSeconds <= 10 else {
            throw HostStateMonitorError.invalidSampleInterval
        }
        guard
            readyFileDescriptor >= 0,
            stopFileDescriptor >= 0,
            fcntl(readyFileDescriptor, F_GETFD) != -1,
            fcntl(stopFileDescriptor, F_GETFD) != -1
        else {
            throw HostStateMonitorError.invalidFileDescriptor
        }
        guard maximumSampleCount >= 2 else {
            throw HostStateMonitorError.invalidSampleLimit
        }

        let recorder = HostStateSampleRecorder(
            maximumSampleCount: maximumSampleCount,
            snapshotProvider: snapshotProvider
        )
        let notificationCallbacks = HostStateNotificationCallbacks(
            recorder: recorder,
            operationQueue: notificationQueue
        )
        try recorder.capture()
        _ = ProcessInfo.processInfo.thermalState
        let thermalObserver = notificationCenter.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCallbacks.enqueue(.thermalState)
        }
        let lowPowerObserver = notificationCenter.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: nil
        ) { _ in
            notificationCallbacks.enqueue(.lowPowerMode)
        }
        var powerSourceObserver: PowerSourceChangeObserver?
        var cleanupCompleted = false
        defer {
            notificationCenter.removeObserver(thermalObserver)
            notificationCenter.removeObserver(lowPowerObserver)
            if !cleanupCompleted {
                try? powerSourceObserver?.stop()
                notificationCallbacks.closeAndDrain()
            }
        }
        powerSourceObserver = try PowerSourceChangeObserver.startIfRequested(
            observePowerSourceChanges
        ) {
            notificationCallbacks.enqueue(.powerSource)
        }

        try writeReadySignal(to: readyFileDescriptor)
        let timeoutMilliseconds = Int32(ceil(sampleIntervalSeconds * 1_000))
        var descriptor = pollfd(
            fd: stopFileDescriptor,
            events: Int16(POLLIN | POLLHUP),
            revents: 0
        )
        while true {
            descriptor.revents = 0
            let status = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
            if status < 0 {
                if errno == EINTR {
                    continue
                }
                throw HostStateMonitorError.pollFailed(errno)
            }
            if status > 0 {
                if descriptor.revents & Int16(POLLERR | POLLNVAL) != 0 {
                    throw HostStateMonitorError.invalidStopDescriptor
                }
                if descriptor.revents & Int16(POLLIN | POLLHUP) == 0 {
                    throw HostStateMonitorError.unexpectedPollEvent(descriptor.revents)
                }
                break
            }
            try recorder.capture()
        }
        notificationCenter.removeObserver(thermalObserver)
        notificationCenter.removeObserver(lowPowerObserver)
        try powerSourceObserver?.stop()
        notificationCallbacks.closeAndDrain()
        cleanupCompleted = true
        try recorder.capture()
        let records = try recorder.records()
        return HostStateMonitorReceipt(
            schemaVersion: 1,
            monotonicClock: "mach_absolute_time",
            sampleIntervalSeconds: sampleIntervalSeconds,
            samples: records.samples,
            events: records.events
        )
    }

    private static func writeReadySignal(to fileDescriptor: Int32) throws {
        var ready: UInt8 = 1
        while true {
            let count = Darwin.write(fileDescriptor, &ready, 1)
            if count == 1 {
                return
            }
            if count < 0, errno == EINTR {
                continue
            }
            throw HostStateMonitorError.readySignalFailed(errno)
        }
    }
}

private final class HostStateSampleRecorder: @unchecked Sendable {
    private let maximumSampleCount: Int
    private let snapshotProvider: @Sendable () throws -> HostStateSnapshot
    private let lock = NSLock()
    private var recordedSamples: [HostStateSample] = []
    private var recordedEvents: [HostStateChangeEvent] = []
    private var failure: Error?

    init(
        maximumSampleCount: Int,
        snapshotProvider: @escaping @Sendable () throws -> HostStateSnapshot
    ) {
        self.maximumSampleCount = maximumSampleCount
        self.snapshotProvider = snapshotProvider
    }

    func capture() throws {
        lock.lock()
        defer { lock.unlock() }
        if let failure {
            throw failure
        }
        guard recordedSamples.count < maximumSampleCount else {
            throw HostStateMonitorError.sampleLimitExceeded
        }
        recordedSamples.append(
            try makeSample(after: recordedSamples.last?.monotonicSeconds)
        )
    }

    func captureFromNotification(
        _ kind: HostStateChangeEvent.Kind,
        enteredAt monotonicSeconds: TimeInterval
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return }
        guard recordedSamples.count < maximumSampleCount else {
            failure = HostStateMonitorError.sampleLimitExceeded
            return
        }
        recordedEvents.append(
            HostStateChangeEvent(monotonicSeconds: monotonicSeconds, kind: kind)
        )
        do {
            recordedSamples.append(
                try makeSample(after: recordedSamples.last?.monotonicSeconds)
            )
        } catch {
            failure = error
        }
    }

    func records() throws -> (
        samples: [HostStateSample],
        events: [HostStateChangeEvent]
    ) {
        lock.lock()
        defer { lock.unlock() }
        if let failure {
            throw failure
        }
        return (
            recordedSamples,
            recordedEvents.sorted {
                if $0.monotonicSeconds != $1.monotonicSeconds {
                    return $0.monotonicSeconds < $1.monotonicSeconds
                }
                return $0.kind.rawValue < $1.kind.rawValue
            }
        )
    }

    private func makeSample(after previousTimestamp: TimeInterval?) throws -> HostStateSample {
        let started = monotonicSeconds()
        let state = try snapshotProvider()
        let ended = monotonicSeconds()
        let midpoint = started + (ended - started) / 2
        let timestamp = previousTimestamp.map { max(midpoint, $0.nextUp) } ?? midpoint
        return HostStateSample(
            monotonicSeconds: timestamp,
            state: state
        )
    }
}

private final class HostStateNotificationCallbacks: @unchecked Sendable {
    let operationQueue: OperationQueue

    private let recorder: HostStateSampleRecorder
    private let condition = NSCondition()
    private var acceptingCallbacks = true
    private var activeEnqueues = 0

    init(recorder: HostStateSampleRecorder, operationQueue: OperationQueue?) {
        self.recorder = recorder
        if let operationQueue {
            self.operationQueue = operationQueue
        } else {
            let queue = OperationQueue()
            queue.name = "EasySplat host state callbacks"
            queue.maxConcurrentOperationCount = 1
            self.operationQueue = queue
        }
    }

    func enqueue(_ kind: HostStateChangeEvent.Kind) {
        let enteredAt = monotonicSeconds()
        condition.lock()
        guard acceptingCallbacks else {
            condition.unlock()
            return
        }
        activeEnqueues += 1
        condition.unlock()
        operationQueue.addOperation { [recorder] in
            recorder.captureFromNotification(kind, enteredAt: enteredAt)
        }
        condition.lock()
        activeEnqueues -= 1
        if activeEnqueues == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }

    func closeAndDrain() {
        condition.lock()
        acceptingCallbacks = false
        while activeEnqueues > 0 {
            condition.wait()
        }
        condition.unlock()
        operationQueue.waitUntilAllOperationsAreFinished()
    }
}

final class PowerSourceChangeObserver: @unchecked Sendable {
    private typealias SourceFactory = @Sendable (
        PowerSourceChangeObserver
    ) -> CFRunLoopSource?

    private let callback: @Sendable () -> Void
    private let startupTimeoutSeconds: TimeInterval
    private let shutdownTimeoutSeconds: TimeInterval
    private let sourceFactory: SourceFactory
    private let beforeSourceCreation: @Sendable () -> Void
    private let beforeThreadExit: @Sendable () -> Void
    private let ready = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var started = false
    private var stopRequested = false
    private var didFinish = false

    private init(
        callback: @escaping @Sendable () -> Void,
        startupTimeoutSeconds: TimeInterval,
        shutdownTimeoutSeconds: TimeInterval,
        sourceFactory: @escaping SourceFactory,
        beforeSourceCreation: @escaping @Sendable () -> Void,
        beforeThreadExit: @escaping @Sendable () -> Void
    ) {
        self.callback = callback
        self.startupTimeoutSeconds = startupTimeoutSeconds
        self.shutdownTimeoutSeconds = shutdownTimeoutSeconds
        self.sourceFactory = sourceFactory
        self.beforeSourceCreation = beforeSourceCreation
        self.beforeThreadExit = beforeThreadExit
    }

    static func startIfRequested(
        _ requested: Bool,
        callback: @escaping @Sendable () -> Void
    ) throws -> PowerSourceChangeObserver? {
        guard requested else { return nil }
        let observer = PowerSourceChangeObserver(
            callback: callback,
            startupTimeoutSeconds: 5,
            shutdownTimeoutSeconds: 5,
            sourceFactory: makeSystemSource,
            beforeSourceCreation: {},
            beforeThreadExit: {}
        )
        try observer.start()
        return observer
    }

    static func startForTesting(
        startupTimeoutSeconds: TimeInterval,
        shutdownTimeoutSeconds: TimeInterval,
        sourceFactory: @escaping @Sendable (
            PowerSourceChangeObserver
        ) -> CFRunLoopSource?,
        beforeSourceCreation: @escaping @Sendable () -> Void = {},
        beforeThreadExit: @escaping @Sendable () -> Void = {}
    ) throws -> PowerSourceChangeObserver {
        let observer = PowerSourceChangeObserver(
            callback: {},
            startupTimeoutSeconds: startupTimeoutSeconds,
            shutdownTimeoutSeconds: shutdownTimeoutSeconds,
            sourceFactory: sourceFactory,
            beforeSourceCreation: beforeSourceCreation,
            beforeThreadExit: beforeThreadExit
        )
        try observer.start()
        return observer
    }

    private func start() throws {
        let thread = Thread { [self] in
            run()
        }
        thread.name = "EasySplat host power monitor"
        thread.start()
        guard ready.wait(timeout: .now() + startupTimeoutSeconds) == .success else {
            requestStop()
            try waitUntilFinished(timeoutSeconds: shutdownTimeoutSeconds)
            throw HostStateMonitorError.powerObserverStartupTimedOut
        }
        lock.lock()
        let didStart = started
        lock.unlock()
        guard didStart else {
            try waitUntilFinished(timeoutSeconds: shutdownTimeoutSeconds)
            throw HostStateMonitorError.powerObserverUnavailable
        }
    }

    private func run() {
        beforeSourceCreation()
        guard let source = sourceFactory(self) else {
            ready.signal()
            finish()
            return
        }
        let currentRunLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(currentRunLoop, source, .defaultMode)
        lock.lock()
        runLoop = currentRunLoop
        started = !stopRequested
        let shouldRun = !stopRequested
        lock.unlock()
        ready.signal()
        if shouldRun {
            CFRunLoopRun()
        }
        CFRunLoopRemoveSource(currentRunLoop, source, .defaultMode)
        lock.lock()
        runLoop = nil
        lock.unlock()
        beforeThreadExit()
        finish()
    }

    private static func makeSystemSource(
        for observer: PowerSourceChangeObserver
    ) -> CFRunLoopSource? {
        IOPSCreateLimitedPowerNotification(
            { context in
                guard let context else { return }
                Unmanaged<PowerSourceChangeObserver>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                    .callback()
            },
            Unmanaged.passUnretained(observer).toOpaque()
        )?.takeRetainedValue()
    }

    private func finish() {
        lock.lock()
        didFinish = true
        lock.unlock()
        finished.signal()
    }

    private func requestStop() {
        lock.lock()
        stopRequested = true
        let currentRunLoop = runLoop
        lock.unlock()
        if let currentRunLoop {
            CFRunLoopStop(currentRunLoop)
            CFRunLoopWakeUp(currentRunLoop)
        }
    }

    func stop(timeoutSeconds: TimeInterval? = nil) throws {
        requestStop()
        try waitUntilFinished(
            timeoutSeconds: timeoutSeconds ?? shutdownTimeoutSeconds
        )
    }

    private func waitUntilFinished(timeoutSeconds: TimeInterval) throws {
        lock.lock()
        let alreadyFinished = didFinish
        lock.unlock()
        guard !alreadyFinished else { return }
        guard finished.wait(timeout: .now() + timeoutSeconds) == .success else {
            throw HostStateMonitorError.powerObserverShutdownTimedOut
        }
        finished.signal()
        lock.lock()
        let confirmedFinished = didFinish
        lock.unlock()
        guard confirmedFinished else {
            throw HostStateMonitorError.powerObserverShutdownTimedOut
        }
    }
}

private func monotonicSeconds() -> TimeInterval {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return Double(mach_absolute_time())
        * Double(timebase.numer)
        / Double(timebase.denom)
        / 1_000_000_000
}

private enum HostStateMonitorError: LocalizedError {
    case invalidSampleInterval
    case invalidFileDescriptor
    case invalidSampleLimit
    case sampleLimitExceeded
    case pollFailed(Int32)
    case invalidStopDescriptor
    case unexpectedPollEvent(Int16)
    case readySignalFailed(Int32)
    case powerObserverStartupTimedOut
    case powerObserverShutdownTimedOut
    case powerObserverUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidSampleInterval:
            "Host monitoring requires a sample interval from 0.05 through 10 seconds."
        case .invalidFileDescriptor:
            "Host monitoring requires valid ready and stop file descriptors."
        case .invalidSampleLimit:
            "Host monitoring requires room for an initial and final sample."
        case .sampleLimitExceeded:
            "Host monitoring exceeded its bounded sample capacity."
        case .pollFailed(let code):
            "Host monitoring failed while waiting for stop with errno \(code)."
        case .invalidStopDescriptor:
            "Host monitoring lost its stop descriptor."
        case .unexpectedPollEvent(let event):
            "Host monitoring received an unexpected stop event \(event)."
        case .readySignalFailed(let code):
            "Host monitoring could not report readiness with errno \(code)."
        case .powerObserverStartupTimedOut:
            "Host monitoring timed out while starting power-source observation."
        case .powerObserverShutdownTimedOut:
            "Host monitoring timed out while stopping power-source observation."
        case .powerObserverUnavailable:
            "Host monitoring could not observe power-source changes."
        }
    }
}

private enum HostStateSnapshotError: LocalizedError {
    case hostStatistics(kern_return_t)
    case unsupportedThermalState
    case powerSourceUnavailable

    var errorDescription: String? {
        switch self {
        case .hostStatistics(let status):
            "Host statistics failed with status \(status)."
        case .unsupportedThermalState:
            "The current thermal state is unsupported."
        case .powerSourceUnavailable:
            "The current power source is unavailable."
        }
    }
}
