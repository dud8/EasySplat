import Foundation

struct AutoTuneProfile: Sendable {
    let tier: HardwareProfile.Tier
    let colmapMaxNumFeatures: Int
    let colmapMaxNumMatches: Int
    let sequentialOverlap: Int
    let exhaustiveBlockSize: Int
    let threadCap: Int
    let colmapMaxImageSizeCap: Int?

    func summary(profile: HardwareProfile) -> String {
        let memText = String(format: "%.1fGB", profile.memoryGB)
        let gpuText: String = {
            guard let gpu = profile.gpuWorkingSetGB else { return "n/a" }
            return String(format: "%.1fGB", gpu)
        }()
        let capText = colmapMaxImageSizeCap.map { "\($0)px" } ?? "none"
        return "Auto-tune: tier=\(tier.rawValue) mem=\(memText) cpu=\(profile.cpuCount) gpuWS=\(gpuText) colmap{features=\(colmapMaxNumFeatures), matches=\(colmapMaxNumMatches), overlap=\(sequentialOverlap), block=\(exhaustiveBlockSize), threads<=\(threadCap)} colmapMaxImageSizeCap=\(capText)"
    }
}

enum AutoTuner {
    static func make(profile: HardwareProfile, preset: PresetSpec, selectedFrameCount: Int) -> AutoTuneProfile {
        _ = preset
        _ = selectedFrameCount
        switch profile.tier {
        case .low:
            return AutoTuneProfile(
                tier: .low,
                colmapMaxNumFeatures: 4_096,
                colmapMaxNumMatches: 4_096,
                sequentialOverlap: 8,
                exhaustiveBlockSize: 10,
                threadCap: 4,
                colmapMaxImageSizeCap: 1200
            )
        case .mid:
            return AutoTuneProfile(
                tier: .mid,
                colmapMaxNumFeatures: 8_192,
                colmapMaxNumMatches: 8_192,
                sequentialOverlap: 10,
                exhaustiveBlockSize: 20,
                threadCap: 6,
                colmapMaxImageSizeCap: nil
            )
        case .high:
            return AutoTuneProfile(
                tier: .high,
                colmapMaxNumFeatures: 10_000,
                colmapMaxNumMatches: 10_000,
                sequentialOverlap: 12,
                exhaustiveBlockSize: 25,
                threadCap: 8,
                colmapMaxImageSizeCap: nil
            )
        }
    }
}
