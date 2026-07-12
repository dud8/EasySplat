import Foundation

#if os(macOS)
import Darwin

final class GeometryMemorySampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.easysplat.geometry-memory")
    private let rootPID: pid_t
    private let sampleInterval: TimeInterval
    private var timer: DispatchSourceTimer?
    private var peakBytes: Int64 = 0
    private var isRunning = false

    init(rootPID: pid_t = getpid(), sampleInterval: TimeInterval = 0.05) {
        self.rootPID = rootPID
        self.sampleInterval = max(0.001, sampleInterval)
    }

    func start() {
        queue.sync {
            guard !isRunning else { return }
            peakBytes = 0
            isRunning = true
            sampleLocked()

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now() + sampleInterval,
                repeating: sampleInterval,
                leeway: .milliseconds(5)
            )
            timer.setEventHandler { [weak self] in
                self?.sampleLocked()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func sampledPeak() -> Int64? {
        queue.sync {
            guard isRunning else { return peakBytes > 0 ? peakBytes : nil }
            sampleLocked()
            return peakBytes > 0 ? peakBytes : nil
        }
    }

    func stop() -> Int64? {
        queue.sync {
            guard isRunning else { return peakBytes > 0 ? peakBytes : nil }
            sampleLocked()
            isRunning = false
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            return peakBytes > 0 ? peakBytes : nil
        }
    }

    func cancel() {
        _ = stop()
    }

    deinit {
        timer?.setEventHandler {}
        timer?.cancel()
    }

    private func sampleLocked() {
        guard isRunning,
              let currentBytes = Self.processTreePhysicalFootprintBytes(rootPID: rootPID) else {
            return
        }
        peakBytes = max(peakBytes, currentBytes)
    }

    private static func processTreePhysicalFootprintBytes(rootPID: pid_t) -> Int64? {
        var pending = [rootPID]
        var visited = Set<pid_t>()
        var total: UInt64 = 0
        var measuredProcess = false

        while let pid = pending.popLast() {
            guard pid > 0, visited.insert(pid).inserted else { continue }
            pending.append(contentsOf: childPIDs(of: pid).filter { !visited.contains($0) })
            guard let footprint = physicalFootprintBytes(of: pid) else { continue }
            measuredProcess = true
            let addition = total.addingReportingOverflow(footprint)
            total = addition.overflow ? UInt64.max : addition.partialValue
        }

        guard measuredProcess else { return nil }
        return Int64(min(total, UInt64(Int64.max)))
    }

    private static func physicalFootprintBytes(of pid: pid_t) -> UInt64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard result == 0 else { return nil }
        return usage.ri_phys_footprint
    }

    private static func childPIDs(of parent: pid_t) -> [pid_t] {
        let capacity = proc_listchildpids(parent, nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listchildpids(parent, buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return Array(pids.prefix(min(Int(count), pids.count))).filter { $0 > 0 }
    }
}
#endif
