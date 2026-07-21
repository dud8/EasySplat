import Foundation

public enum TrainingResourceAdmissionError: Error, LocalizedError, Sendable, Equatable {
    case invalidObservation
    case staleObservation
    case insufficientAvailableMemory(requiredBytes: Int64, availableBytes: Int64)

    public var errorDescription: String? {
        switch self {
        case .invalidObservation:
            "Current memory availability could not be verified."
        case .staleObservation:
            "Memory availability changed before training could start."
        case .insufficientAvailableMemory:
            "Training does not have enough unified memory available right now."
        }
    }
}

public enum TrainingMemoryBudget {
    private static let gibibyte: UInt64 = 1_073_741_824
    private static let mebibyte: UInt64 = 1_048_576
    private static let constrainedMemoryBoundary = 33 * gibibyte / 2
    private static let constrainedMemoryCap = 12 * gibibyte
    private static let maximumObservationAgeNanoseconds: UInt64 = 5_000_000_000
    private static let maximumWallClockSkewSeconds = 1.0

    public static func admit<Observer: TrainingResourceObserving>(
        observing observer: Observer,
        resourcePolicy: ResourcePolicy
    ) throws -> TrainingResourceAdmission {
        let observationStart = try LiveTrainingResourceObserver.captureClockEvidence()
        let observation = try observer.observe()
        let observationEnd = try LiveTrainingResourceObserver.captureClockEvidence()
        guard isFresh(observationStart, relativeTo: observationEnd),
              observation.clock.bootTimeSeconds == observationStart.bootTimeSeconds,
              observation.clock.bootTimeMicroseconds == observationStart.bootTimeMicroseconds,
              observation.clock.machTimebaseNumerator
                == observationStart.machTimebaseNumerator,
              observation.clock.machTimebaseDenominator
                == observationStart.machTimebaseDenominator,
              observation.clock.monotonicTicks >= observationStart.monotonicTicks,
              observation.clock.monotonicTicks <= observationEnd.monotonicTicks else {
            throw TrainingResourceAdmissionError.staleObservation
        }
        return try admit(
            observation: observation,
            resourcePolicy: resourcePolicy,
            freshnessReference: observationEnd
        )
    }

    public static func admit(
        observation: TrainingResourceObservation,
        resourcePolicy: ResourcePolicy,
        freshnessReference: TrainingResourceClockEvidence
    ) throws -> TrainingResourceAdmission {
        guard isValid(observation) else {
            throw TrainingResourceAdmissionError.invalidObservation
        }
        guard isFresh(observation.clock, relativeTo: freshnessReference) else {
            throw TrainingResourceAdmissionError.staleObservation
        }
        return resolvedAdmission(
            observation: observation,
            resourcePolicy: resourcePolicy
        )
    }

    public static func trainerBudget(
        plannedBytes: Int64,
        checkpointBytes: Int64? = nil,
        admission: TrainingResourceAdmission
    ) throws -> Int64 {
        guard plannedBytes > 0,
              isValid(admission),
              admission.allowedTrainerBytes <= UInt64(Int64.max) else {
            throw TrainingResourceAdmissionError.invalidObservation
        }
        let availableBytes = Int64(admission.allowedTrainerBytes)
        if let checkpointBytes {
            guard checkpointBytes > 0, checkpointBytes <= plannedBytes else {
                throw TrainingResourceAdmissionError.invalidObservation
            }
            guard checkpointBytes <= availableBytes else {
                throw TrainingResourceAdmissionError.insufficientAvailableMemory(
                    requiredBytes: checkpointBytes,
                    availableBytes: availableBytes
                )
            }
            return checkpointBytes
        }
        let resolved = min(plannedBytes, availableBytes)
        guard resolved > 0 else {
            throw TrainingResourceAdmissionError.insufficientAvailableMemory(
                requiredBytes: 1,
                availableBytes: availableBytes
            )
        }
        return resolved
    }

    private static func resolvedAdmission(
        observation: TrainingResourceObservation,
        resourcePolicy: ResourcePolicy
    ) -> TrainingResourceAdmission {
        let installedBytes = observation.installedMemoryBytes

        let policyHeadroom = min(
            installedBytes,
            max(2 * gibibyte, installedBytes / 20)
        )
        let policyBase = subtracting(policyHeadroom, from: installedBytes)
        let effectivePolicy: ResourcePolicy
        if resourcePolicy == .maximumPerformance,
           installedBytes <= constrainedMemoryBoundary {
            effectivePolicy = .automatic
        } else {
            effectivePolicy = resourcePolicy
        }
        var policyCapacity = switch effectivePolicy {
        case .conserveMemory:
            scaled(policyBase, numerator: 3, denominator: 5)
        case .automatic:
            scaled(policyBase, numerator: 9, denominator: 10)
        case .maximumPerformance:
            scaled(policyBase, numerator: 49, denominator: 50)
        }
        if installedBytes <= constrainedMemoryBoundary {
            policyCapacity = min(policyCapacity, constrainedMemoryCap)
        }

        let hostHeadroom = min(
            observation.availableHostMemoryBytes,
            max(2 * gibibyte, installedBytes / 20)
        )
        let unpressuredHostCapacity = subtracting(
            hostHeadroom,
            from: observation.availableHostMemoryBytes
        )
        let hostCapacity: UInt64 = switch observation.memoryPressure {
        case .normal:
            unpressuredHostCapacity
        case .warning:
            scaled(unpressuredHostCapacity, numerator: 3, denominator: 5)
        case .critical:
            scaled(unpressuredHostCapacity, numerator: 1, denominator: 3)
        case .unknown:
            scaled(unpressuredHostCapacity, numerator: 4, denominator: 5)
        }

        let metalResolution: (headroom: UInt64?, capacity: UInt64?)
        if let recommended = observation.metalRecommendedWorkingSetBytes,
           recommended > 0 {
            let headroom = min(
                recommended,
                max(512 * mebibyte, recommended / 20)
            )
            let allocated = observation.metalCurrentAllocatedBytes ?? 0
            let capacity = subtracting(
                headroom,
                from: subtracting(allocated, from: recommended)
            )
            metalResolution = (headroom, capacity)
        } else {
            metalResolution = (nil, nil)
        }

        var allowed = min(policyCapacity, hostCapacity)
        if let metalCapacity = metalResolution.capacity {
            allowed = min(allowed, metalCapacity)
        }
        return TrainingResourceAdmission(
            observation: observation,
            resourcePolicy: resourcePolicy,
            policyHeadroomBytes: policyHeadroom,
            policyCapacityBytes: policyCapacity,
            hostHeadroomBytes: hostHeadroom,
            hostCapacityBytes: hostCapacity,
            metalHeadroomBytes: metalResolution.headroom,
            metalCapacityBytes: metalResolution.capacity,
            allowedTrainerBytes: allowed
        )
    }

    public static func isValid(_ admission: TrainingResourceAdmission) -> Bool {
        guard admission.schemaVersion == TrainingResourceAdmission.currentSchemaVersion,
              isValid(admission.observation) else {
            return false
        }
        return resolvedAdmission(
            observation: admission.observation,
            resourcePolicy: admission.resourcePolicy
        ) == admission
    }

    /// A persisted admission is diagnostic evidence, not permission to launch a
    /// later process. Call this again at the immediate trainer boundary.
    public static func isFresh(
        _ admission: TrainingResourceAdmission,
        relativeTo reference: TrainingResourceClockEvidence
    ) -> Bool {
        isValid(admission) && isFresh(admission.observation.clock, relativeTo: reference)
    }

    private static func isValid(_ observation: TrainingResourceObservation) -> Bool {
        let clock = observation.clock
        let pages = observation.hostPages
        guard clock.wallClock.timeIntervalSinceReferenceDate.isFinite,
              clock.monotonicTicks > 0,
              clock.machTimebaseNumerator > 0,
              clock.machTimebaseDenominator > 0,
              clock.bootTimeSeconds > 0,
              clock.bootTimeMicroseconds >= 0,
              clock.bootTimeMicroseconds < 1_000_000,
              observation.installedMemoryBytes > 0,
              observation.availableHostMemoryBytes <= observation.installedMemoryBytes,
              pages.pageSizeBytes > 0,
              pages.speculativePageCount <= pages.freePageCount,
              let fallbackBytes = pages.exactConservativeAvailableBytes,
              fallbackBytes <= observation.installedMemoryBytes,
              exactBytes(pages.speculativePageCount, pageSize: pages.pageSizeBytes)
                .map({ $0 <= observation.installedMemoryBytes }) == true,
              exactBytes(pages.purgeablePageCount, pageSize: pages.pageSizeBytes)
                .map({ $0 <= observation.installedMemoryBytes }) == true,
              exactBytes(pages.compressedPageCount, pageSize: pages.pageSizeBytes)
                .map({ $0 <= observation.installedMemoryBytes }) == true else {
            return false
        }
        let expectedAvailableBytes: UInt64
        switch observation.availableHostMemorySource {
        case .kernelMemorystatusPercentage:
            guard let percentage = observation.kernelAvailableMemoryPercentage,
                  percentage <= 100 else {
                return false
            }
            expectedAvailableBytes = LiveTrainingResourceObserver.availableBytes(
                installedBytes: observation.installedMemoryBytes,
                kernelAvailablePercentage: percentage,
                fallback: 0
            )
        case .machVMFreeInactive:
            guard observation.kernelAvailableMemoryPercentage == nil else {
                return false
            }
            expectedAvailableBytes = fallbackBytes
        }
        guard observation.availableHostMemoryBytes == expectedAvailableBytes else {
            return false
        }
        switch observation.memoryPressureSource {
        case .kernelMemorystatus:
            guard observation.memoryPressure != .unknown else { return false }
        case .unavailable:
            guard observation.memoryPressure == .unknown else { return false }
        }
        switch (
            observation.metalRecommendedWorkingSetBytes,
            observation.metalCurrentAllocatedBytes
        ) {
        case let (recommendation?, allocation?):
            guard recommendation > 0,
                  recommendation <= observation.installedMemoryBytes,
                  allocation <= observation.installedMemoryBytes else {
                return false
            }
        case (nil, nil):
            break
        default:
            return false
        }
        return true
    }

    private static func isFresh(
        _ observation: TrainingResourceClockEvidence,
        relativeTo reference: TrainingResourceClockEvidence
    ) -> Bool {
        guard reference.wallClock.timeIntervalSinceReferenceDate.isFinite,
              reference.monotonicTicks >= observation.monotonicTicks,
              reference.machTimebaseNumerator == observation.machTimebaseNumerator,
              reference.machTimebaseDenominator == observation.machTimebaseDenominator,
              reference.bootTimeSeconds == observation.bootTimeSeconds,
              reference.bootTimeMicroseconds == observation.bootTimeMicroseconds,
              let elapsedNanoseconds = elapsedNanoseconds(
                  from: observation.monotonicTicks,
                  to: reference.monotonicTicks,
                  numerator: observation.machTimebaseNumerator,
                  denominator: observation.machTimebaseDenominator
              ),
              elapsedNanoseconds <= maximumObservationAgeNanoseconds else {
            return false
        }
        let wallClockAge = reference.wallClock.timeIntervalSince(observation.wallClock)
        return wallClockAge.isFinite
            && wallClockAge >= -maximumWallClockSkewSeconds
            && wallClockAge <= Double(maximumObservationAgeNanoseconds) / 1_000_000_000
    }

    private static func elapsedNanoseconds(
        from start: UInt64,
        to end: UInt64,
        numerator: UInt32,
        denominator: UInt32
    ) -> UInt64? {
        guard end >= start, numerator > 0, denominator > 0 else { return nil }
        let ticks = end - start
        let divisor = UInt64(denominator)
        let multiplier = UInt64(numerator)
        let whole = (ticks / divisor).multipliedReportingOverflow(by: multiplier)
        let remainder = (ticks % divisor).multipliedReportingOverflow(by: multiplier)
        guard !whole.overflow, !remainder.overflow else { return nil }
        let fractional = remainder.partialValue / divisor
        let result = whole.partialValue.addingReportingOverflow(fractional)
        return result.overflow ? nil : result.partialValue
    }

    private static func exactBytes(_ pages: UInt64, pageSize: UInt64) -> UInt64? {
        let result = pages.multipliedReportingOverflow(by: pageSize)
        return result.overflow ? nil : result.partialValue
    }

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

    private static func subtracting(_ value: UInt64, from total: UInt64) -> UInt64 {
        total > value ? total - value : 0
    }
}
