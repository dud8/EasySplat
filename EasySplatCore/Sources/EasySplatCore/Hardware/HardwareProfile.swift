import Foundation

#if canImport(Metal)
import Metal
#endif

struct HardwareProfile: Sendable {
    enum Tier: String, Sendable {
        case low = "Low"
        case mid = "Mid"
        case high = "High"
    }

    let memoryGB: Double
    let cpuCount: Int
    let gpuWorkingSetGB: Double?
    let tier: Tier

    init(memoryGB: Double, cpuCount: Int, gpuWorkingSetGB: Double?) {
        self.memoryGB = memoryGB
        self.cpuCount = cpuCount
        self.gpuWorkingSetGB = gpuWorkingSetGB
        self.tier = HardwareProfile.tier(for: memoryGB)
    }

    static func detect() -> HardwareProfile {
        let memoryBytes = ProcessInfo.processInfo.physicalMemory
        let memoryGB = Double(memoryBytes) / 1_073_741_824.0
        let cpuCount = ProcessInfo.processInfo.activeProcessorCount
        let gpuWorkingSetGB = detectRecommendedWorkingSetGB()
        return HardwareProfile(memoryGB: memoryGB, cpuCount: cpuCount, gpuWorkingSetGB: gpuWorkingSetGB)
    }

    static func tier(for memoryGB: Double) -> Tier {
        if memoryGB <= 16.0 { return .low }
        if memoryGB <= 32.0 { return .mid }
        return .high
    }

    private static func detectRecommendedWorkingSetGB() -> Double? {
        #if canImport(Metal)
        if let device = MTLCreateSystemDefaultDevice() {
            let bytes = device.recommendedMaxWorkingSetSize
            if bytes > 0 {
                return Double(bytes) / 1_073_741_824.0
            }
        }
        #endif
        return nil
    }
}
