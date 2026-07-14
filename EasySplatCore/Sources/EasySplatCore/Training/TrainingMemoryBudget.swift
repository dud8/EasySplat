import Foundation

public enum TrainingMemoryBudget {
    private static let gibibyte: UInt64 = 1_073_741_824
    private static let constrainedMemoryBoundary = 33 * gibibyte / 2
    private static let constrainedMemoryCap = 12 * gibibyte

    public static func resolve(
        hardware: HardwareProfile,
        resourcePolicy: ResourcePolicy
    ) -> Int64 {
        guard let physicalMemoryBytes = bytes(fromGibibytes: hardware.memoryGB) else {
            return 0
        }
        return resolve(
            physicalMemoryBytes: physicalMemoryBytes,
            recommendedMetalWorkingSetBytes: hardware.gpuWorkingSetGB.flatMap(bytes(fromGibibytes:)),
            resourcePolicy: resourcePolicy
        )
    }

    public static func resolve(
        physicalMemoryBytes: UInt64,
        recommendedMetalWorkingSetBytes: UInt64?,
        resourcePolicy: ResourcePolicy
    ) -> Int64 {
        guard physicalMemoryBytes > 0 else { return 0 }

        let systemReserve = max(2 * gibibyte, physicalMemoryBytes / 10)
        let physicalHeadroom = physicalMemoryBytes > systemReserve
            ? physicalMemoryBytes - systemReserve
            : physicalMemoryBytes / 2
        let metalHeadroom = recommendedMetalWorkingSetBytes
            .flatMap { $0 > 0 ? min($0, physicalMemoryBytes) : nil }
            ?? physicalHeadroom
        let usableBytes = min(physicalHeadroom, metalHeadroom)

        let effectivePolicy: ResourcePolicy
        if resourcePolicy == .maximumPerformance,
           physicalMemoryBytes <= constrainedMemoryBoundary {
            effectivePolicy = .automatic
        } else {
            effectivePolicy = resourcePolicy
        }

        var budget: UInt64 = switch effectivePolicy {
        case .conserveMemory:
            scaled(usableBytes, numerator: 3, denominator: 5)
        case .automatic:
            scaled(usableBytes, numerator: 9, denominator: 10)
        case .maximumPerformance:
            scaled(usableBytes, numerator: 49, denominator: 50)
        }
        if physicalMemoryBytes <= constrainedMemoryBoundary {
            budget = min(budget, constrainedMemoryCap)
        }
        return Int64(min(budget, UInt64(Int64.max)))
    }

    private static func bytes(fromGibibytes value: Double) -> UInt64? {
        guard value.isFinite, value > 0 else { return nil }
        let bytes = value * Double(gibibyte)
        guard bytes.isFinite else { return nil }
        return bytes >= Double(UInt64.max) ? UInt64.max : UInt64(bytes)
    }

    private static func scaled(
        _ bytes: UInt64,
        numerator: UInt64,
        denominator: UInt64
    ) -> UInt64 {
        (bytes / denominator) * numerator
            + (bytes % denominator) * numerator / denominator
    }
}
