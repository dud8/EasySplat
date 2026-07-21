import Darwin
import Dispatch
import Foundation

#if canImport(Metal)
import Metal
#endif

public enum AvailableHostMemorySource: String, Codable, Sendable, Equatable {
    /// XNU's pressure subsystem estimate, exposed as a percentage of installed
    /// memory by `kern.memorystatus_level`.
    case kernelMemorystatusPercentage = "kernel_memorystatus_percentage"

    /// Conservative fallback used when the pressure-subsystem percentage is
    /// unavailable. XNU already includes speculative pages in `free_count`.
    case machVMFreeInactive = "mach_vm_free_inactive"
}

public enum MemoryPressureState: String, Codable, Sendable, Equatable {
    case normal
    case warning
    case critical
    case unknown
}

public enum MemoryPressureSource: String, Codable, Sendable, Equatable {
    /// Current XNU pressure state from `kern.memorystatus_vm_pressure_level`.
    case kernelMemorystatus = "kernel_memorystatus"
    case unavailable
}

/// Raw Mach VM counters retained with an admission decision. Inactive pages
/// are reclaimable candidates, not guaranteed free memory. Purgeable pages can
/// overlap other VM queues and compressed pages are already occupied, so both
/// are evidence only and are deliberately excluded from the fallback estimate.
public struct HostMemoryPageEvidence: Codable, Sendable, Equatable {
    public var pageSizeBytes: UInt64
    public var freePageCount: UInt64
    public var inactivePageCount: UInt64
    public var speculativePageCount: UInt64
    public var purgeablePageCount: UInt64
    public var compressedPageCount: UInt64

    private enum CodingKeys: String, CodingKey {
        case pageSizeBytes = "page_size_bytes"
        case freePageCount = "free_page_count"
        case inactivePageCount = "inactive_page_count"
        case speculativePageCount = "speculative_page_count"
        case purgeablePageCount = "purgeable_page_count"
        case compressedPageCount = "compressed_page_count"
    }

    public init(
        pageSizeBytes: UInt64,
        freePageCount: UInt64,
        inactivePageCount: UInt64,
        speculativePageCount: UInt64,
        purgeablePageCount: UInt64,
        compressedPageCount: UInt64
    ) {
        self.pageSizeBytes = pageSizeBytes
        self.freePageCount = freePageCount
        self.inactivePageCount = inactivePageCount
        self.speculativePageCount = speculativePageCount
        self.purgeablePageCount = purgeablePageCount
        self.compressedPageCount = compressedPageCount
    }

    public var conservativeAvailableBytes: UInt64 {
        let pageCount = Self.saturatingAdd(freePageCount, inactivePageCount)
        return Self.saturatingMultiply(pageCount, pageSizeBytes)
    }

    var exactConservativeAvailableBytes: UInt64? {
        let pageCount = freePageCount.addingReportingOverflow(inactivePageCount)
        guard !pageCount.overflow else { return nil }
        let bytes = pageCount.partialValue.multipliedReportingOverflow(by: pageSizeBytes)
        return bytes.overflow ? nil : bytes.partialValue
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }

    private static func saturatingMultiply(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let result = lhs.multipliedReportingOverflow(by: rhs)
        return result.overflow ? .max : result.partialValue
    }
}

/// Boot-bound clock evidence used to prove that a memory observation is still
/// current when the trainer is admitted. Persisted values explain a decision;
/// they are never reusable authorization for a later launch.
public struct TrainingResourceClockEvidence: Codable, Sendable, Equatable {
    public var wallClock: Date
    public var monotonicTicks: UInt64
    public var machTimebaseNumerator: UInt32
    public var machTimebaseDenominator: UInt32
    public var bootTimeSeconds: Int64
    public var bootTimeMicroseconds: Int32

    private enum CodingKeys: String, CodingKey {
        case wallClock = "wall_clock"
        case monotonicTicks = "monotonic_ticks"
        case machTimebaseNumerator = "mach_timebase_numerator"
        case machTimebaseDenominator = "mach_timebase_denominator"
        case bootTimeSeconds = "boot_time_seconds"
        case bootTimeMicroseconds = "boot_time_microseconds"
    }

    public init(
        wallClock: Date,
        monotonicTicks: UInt64,
        machTimebaseNumerator: UInt32,
        machTimebaseDenominator: UInt32,
        bootTimeSeconds: Int64,
        bootTimeMicroseconds: Int32
    ) {
        self.wallClock = wallClock
        self.monotonicTicks = monotonicTicks
        self.machTimebaseNumerator = machTimebaseNumerator
        self.machTimebaseDenominator = machTimebaseDenominator
        self.bootTimeSeconds = bootTimeSeconds
        self.bootTimeMicroseconds = bootTimeMicroseconds
    }
}

/// One live observation at the trainer-admission boundary. It is intentionally
/// serializable so a run can explain exactly which changing system state was
/// used, without persisting project paths or user-authored content.
public struct TrainingResourceObservation: Codable, Sendable, Equatable {
    public var clock: TrainingResourceClockEvidence
    public var installedMemoryBytes: UInt64
    public var availableHostMemoryBytes: UInt64
    public var availableHostMemorySource: AvailableHostMemorySource
    public var kernelAvailableMemoryPercentage: UInt32?
    public var hostPages: HostMemoryPageEvidence
    public var memoryPressure: MemoryPressureState
    public var memoryPressureSource: MemoryPressureSource
    public var metalRecommendedWorkingSetBytes: UInt64?
    public var metalCurrentAllocatedBytes: UInt64?

    private enum CodingKeys: String, CodingKey {
        case clock
        case installedMemoryBytes = "installed_memory_bytes"
        case availableHostMemoryBytes = "available_host_memory_bytes"
        case availableHostMemorySource = "available_host_memory_source"
        case kernelAvailableMemoryPercentage = "kernel_available_memory_percentage"
        case hostPages = "host_pages"
        case memoryPressure = "memory_pressure"
        case memoryPressureSource = "memory_pressure_source"
        case metalRecommendedWorkingSetBytes = "metal_recommended_working_set_bytes"
        case metalCurrentAllocatedBytes = "metal_current_allocated_bytes"
    }

    public init(
        clock: TrainingResourceClockEvidence,
        installedMemoryBytes: UInt64,
        availableHostMemoryBytes: UInt64,
        availableHostMemorySource: AvailableHostMemorySource,
        kernelAvailableMemoryPercentage: UInt32?,
        hostPages: HostMemoryPageEvidence,
        memoryPressure: MemoryPressureState,
        memoryPressureSource: MemoryPressureSource,
        metalRecommendedWorkingSetBytes: UInt64?,
        metalCurrentAllocatedBytes: UInt64?
    ) {
        self.clock = clock
        self.installedMemoryBytes = installedMemoryBytes
        self.availableHostMemoryBytes = availableHostMemoryBytes
        self.availableHostMemorySource = availableHostMemorySource
        self.kernelAvailableMemoryPercentage = kernelAvailableMemoryPercentage
        self.hostPages = hostPages
        self.memoryPressure = memoryPressure
        self.memoryPressureSource = memoryPressureSource
        self.metalRecommendedWorkingSetBytes = metalRecommendedWorkingSetBytes
        self.metalCurrentAllocatedBytes = metalCurrentAllocatedBytes
    }
}

public protocol TrainingResourceObserving: Sendable {
    func observe() throws -> TrainingResourceObservation
}

/// Reads the live macOS admission evidence without launching helper processes
/// or allocating memory to discover the failure point.
public struct LiveTrainingResourceObserver: TrainingResourceObserving {
    public init() {}

    public func observe() throws -> TrainingResourceObservation {
        let clock = try Self.captureClockEvidence()
        let installedBytes = ProcessInfo.processInfo.physicalMemory
        let pages = try Self.captureHostPages()
        let availablePercentage = Self.readUInt32Sysctl("kern.memorystatus_level")
            .flatMap { $0 <= 100 ? $0 : nil }
        let fallbackBytes = min(installedBytes, pages.conservativeAvailableBytes)
        let availableBytes = Self.availableBytes(
            installedBytes: installedBytes,
            kernelAvailablePercentage: availablePercentage,
            fallback: fallbackBytes
        )
        let pressureRaw = Self.readUInt32Sysctl(
            "kern.memorystatus_vm_pressure_level"
        )
        let pressure = Self.pressureState(rawDispatchLevel: pressureRaw)
        #if canImport(Metal)
        let device = MTLCreateSystemDefaultDevice()
        let metalEvidence = device.flatMap { device -> (UInt64, UInt64)? in
            let bytes = UInt64(device.recommendedMaxWorkingSetSize)
            return bytes > 0 ? (bytes, UInt64(device.currentAllocatedSize)) : nil
        }
        let recommendedBytes = metalEvidence?.0
        let allocatedBytes = metalEvidence?.1
        #else
        let recommendedBytes: UInt64? = nil
        let allocatedBytes: UInt64? = nil
        #endif
        return TrainingResourceObservation(
            clock: clock,
            installedMemoryBytes: installedBytes,
            availableHostMemoryBytes: availableBytes,
            availableHostMemorySource: availablePercentage == nil
                ? .machVMFreeInactive
                : .kernelMemorystatusPercentage,
            kernelAvailableMemoryPercentage: availablePercentage,
            hostPages: pages,
            memoryPressure: pressure.state,
            memoryPressureSource: pressure.source,
            metalRecommendedWorkingSetBytes: recommendedBytes,
            metalCurrentAllocatedBytes: allocatedBytes
        )
    }

    static func captureClockEvidence() throws -> TrainingResourceClockEvidence {
        var timebase = mach_timebase_info_data_t()
        let timebaseStatus = mach_timebase_info(&timebase)
        guard timebaseStatus == KERN_SUCCESS, timebase.numer > 0, timebase.denom > 0 else {
            throw TrainingResourceObservationError.machTimebase(timebaseStatus)
        }

        var bootTime = timeval()
        var bootTimeSize = MemoryLayout<timeval>.size
        let bootTimeResult = "kern.boottime".withCString { pointer in
            sysctlbyname(pointer, &bootTime, &bootTimeSize, nil, 0)
        }
        guard bootTimeResult == 0,
              bootTimeSize == MemoryLayout<timeval>.size,
              bootTime.tv_sec > 0,
              bootTime.tv_usec >= 0,
              bootTime.tv_usec < 1_000_000,
              let bootMicroseconds = Int32(exactly: bootTime.tv_usec) else {
            throw TrainingResourceObservationError.bootTime(
                bootTimeResult == 0 ? EINVAL : errno
            )
        }

        return TrainingResourceClockEvidence(
            wallClock: Date(),
            monotonicTicks: mach_continuous_time(),
            machTimebaseNumerator: timebase.numer,
            machTimebaseDenominator: timebase.denom,
            bootTimeSeconds: Int64(bootTime.tv_sec),
            bootTimeMicroseconds: bootMicroseconds
        )
    }

    static func availableBytes(
        installedBytes: UInt64,
        kernelAvailablePercentage: UInt32?,
        fallback: UInt64
    ) -> UInt64 {
        guard let percentage = kernelAvailablePercentage else {
            return min(installedBytes, fallback)
        }
        let clampedPercentage = UInt64(min(percentage, 100))
        let quotient = installedBytes / 100
        let remainder = installedBytes % 100
        let scaled = quotient * clampedPercentage
            + remainder * clampedPercentage / 100
        return min(installedBytes, scaled)
    }

    private static func captureHostPages() throws -> HostMemoryPageEvidence {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        let pageStatus = host_page_size(host, &pageSize)
        guard pageStatus == KERN_SUCCESS, pageSize > 0 else {
            throw TrainingResourceObservationError.hostPageSize(pageStatus)
        }

        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size
                / MemoryLayout<integer_t>.size
        )
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else {
            throw TrainingResourceObservationError.hostStatistics(status)
        }
        return HostMemoryPageEvidence(
            pageSizeBytes: UInt64(pageSize),
            freePageCount: UInt64(statistics.free_count),
            inactivePageCount: UInt64(statistics.inactive_count),
            speculativePageCount: UInt64(statistics.speculative_count),
            purgeablePageCount: UInt64(statistics.purgeable_count),
            compressedPageCount: UInt64(statistics.compressor_page_count)
        )
    }

    private static func readUInt32Sysctl(_ name: String) -> UInt32? {
        var value: UInt32 = 0
        var size = MemoryLayout<UInt32>.size
        let result = name.withCString { pointer in
            sysctlbyname(pointer, &value, &size, nil, 0)
        }
        guard result == 0, size == MemoryLayout<UInt32>.size else { return nil }
        return value
    }

    static func pressureState(
        rawDispatchLevel: UInt32?
    ) -> (state: MemoryPressureState, source: MemoryPressureSource) {
        switch rawDispatchLevel {
        case UInt32(DispatchSource.MemoryPressureEvent.normal.rawValue):
            (.normal, .kernelMemorystatus)
        case UInt32(DispatchSource.MemoryPressureEvent.warning.rawValue):
            (.warning, .kernelMemorystatus)
        case UInt32(DispatchSource.MemoryPressureEvent.critical.rawValue):
            (.critical, .kernelMemorystatus)
        default:
            (.unknown, .unavailable)
        }
    }
}

public enum TrainingResourceObservationError: Error, Equatable {
    case hostPageSize(kern_return_t)
    case hostStatistics(kern_return_t)
    case machTimebase(kern_return_t)
    case bootTime(Int32)
}

/// Final, versioned decision passed to the trainer boundary.
public struct TrainingResourceAdmission: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var observation: TrainingResourceObservation
    public var resourcePolicy: ResourcePolicy
    public var policyHeadroomBytes: UInt64
    public var policyCapacityBytes: UInt64
    public var hostHeadroomBytes: UInt64
    public var hostCapacityBytes: UInt64
    public var metalHeadroomBytes: UInt64?
    public var metalCapacityBytes: UInt64?
    public var allowedTrainerBytes: UInt64

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case observation
        case resourcePolicy = "resource_policy"
        case policyHeadroomBytes = "policy_headroom_bytes"
        case policyCapacityBytes = "policy_capacity_bytes"
        case hostHeadroomBytes = "host_headroom_bytes"
        case hostCapacityBytes = "host_capacity_bytes"
        case metalHeadroomBytes = "metal_headroom_bytes"
        case metalCapacityBytes = "metal_capacity_bytes"
        case allowedTrainerBytes = "allowed_trainer_bytes"
    }

    public init(
        schemaVersion: Int = currentSchemaVersion,
        observation: TrainingResourceObservation,
        resourcePolicy: ResourcePolicy,
        policyHeadroomBytes: UInt64,
        policyCapacityBytes: UInt64,
        hostHeadroomBytes: UInt64,
        hostCapacityBytes: UInt64,
        metalHeadroomBytes: UInt64?,
        metalCapacityBytes: UInt64?,
        allowedTrainerBytes: UInt64
    ) {
        self.schemaVersion = schemaVersion
        self.observation = observation
        self.resourcePolicy = resourcePolicy
        self.policyHeadroomBytes = policyHeadroomBytes
        self.policyCapacityBytes = policyCapacityBytes
        self.hostHeadroomBytes = hostHeadroomBytes
        self.hostCapacityBytes = hostCapacityBytes
        self.metalHeadroomBytes = metalHeadroomBytes
        self.metalCapacityBytes = metalCapacityBytes
        self.allowedTrainerBytes = allowedTrainerBytes
    }
}

/// Path-free training memory metrics suitable for diagnostic JSON.
public struct TrainingResourceDiagnosticEvidence: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var admission: TrainingResourceAdmission
    public var memoryBudgetBytes: UInt64
    public var peakMemoryBytes: UInt64
    public var rasterExactBufferGrowthCount: UInt64
    public var rasterExactBufferBytesAdded: UInt64

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case admission
        case memoryBudgetBytes = "memory_budget_bytes"
        case peakMemoryBytes = "peak_memory_bytes"
        case rasterExactBufferGrowthCount = "raster_exact_buffer_growth_count"
        case rasterExactBufferBytesAdded = "raster_exact_buffer_bytes_added"
    }

    public init(
        schemaVersion: Int = currentSchemaVersion,
        admission: TrainingResourceAdmission,
        memoryBudgetBytes: UInt64,
        peakMemoryBytes: UInt64,
        rasterExactBufferGrowthCount: UInt64,
        rasterExactBufferBytesAdded: UInt64
    ) {
        self.schemaVersion = schemaVersion
        self.admission = admission
        self.memoryBudgetBytes = memoryBudgetBytes
        self.peakMemoryBytes = peakMemoryBytes
        self.rasterExactBufferGrowthCount = rasterExactBufferGrowthCount
        self.rasterExactBufferBytesAdded = rasterExactBufferBytesAdded
    }
}
