import Foundation

struct AutoTuneProfile: Sendable {
    let tier: HardwareProfile.Tier
    let vggtImageLoadResolution: Int
    let vggtFixedResolution: Int
    let vggtMaxPoints: Int
    let colmapMaxNumFeatures: Int
    let colmapMaxNumMatches: Int
    let sequentialOverlap: Int
    let exhaustiveBlockSize: Int
    let threadCap: Int
    let colmapMaxImageSizeCap: Int?
    let vggtAllowed: Bool

    func summary(profile: HardwareProfile) -> String {
        let memText = String(format: "%.1fGB", profile.memoryGB)
        let gpuText: String = {
            guard let gpu = profile.gpuWorkingSetGB else { return "n/a" }
            return String(format: "%.1fGB", gpu)
        }()
        let capText = colmapMaxImageSizeCap.map { "\($0)px" } ?? "none"
        return "Auto-tune: tier=\(tier.rawValue) mem=\(memText) cpu=\(profile.cpuCount) gpuWS=\(gpuText) vggtAllowed=\(vggtAllowed ? "yes" : "no") vggt{imgLoad=\(vggtImageLoadResolution), vggt=\(vggtFixedResolution), maxPoints=\(vggtMaxPoints)} colmap{features=\(colmapMaxNumFeatures), matches=\(colmapMaxNumMatches), overlap=\(sequentialOverlap), block=\(exhaustiveBlockSize), threads<=\(threadCap)} colmapMaxImageSizeCap=\(capText)"
    }
}

enum AutoTuner {
    static func make(profile: HardwareProfile, preset: PresetSpec, selectedFrameCount: Int) -> AutoTuneProfile {
        _ = preset
        _ = selectedFrameCount
        switch profile.tier {
        case .low:
            let vggtAllowed = profile.memoryGB >= 12.0 && (profile.gpuWorkingSetGB ?? 999.0) >= 4.0
            return AutoTuneProfile(
                tier: .low,
                vggtImageLoadResolution: 768,
                vggtFixedResolution: 448,
                vggtMaxPoints: 60_000,
                colmapMaxNumFeatures: 4_096,
                colmapMaxNumMatches: 4_096,
                sequentialOverlap: 8,
                exhaustiveBlockSize: 10,
                threadCap: 4,
                colmapMaxImageSizeCap: 1200,
                vggtAllowed: vggtAllowed
            )
        case .mid:
            return AutoTuneProfile(
                tier: .mid,
                vggtImageLoadResolution: 1024,
                vggtFixedResolution: 518,
                vggtMaxPoints: 100_000,
                colmapMaxNumFeatures: 8_192,
                colmapMaxNumMatches: 8_192,
                sequentialOverlap: 10,
                exhaustiveBlockSize: 20,
                threadCap: 6,
                colmapMaxImageSizeCap: nil,
                vggtAllowed: true
            )
        case .high:
            return AutoTuneProfile(
                tier: .high,
                vggtImageLoadResolution: 1280,
                vggtFixedResolution: 518,
                vggtMaxPoints: 150_000,
                colmapMaxNumFeatures: 10_000,
                colmapMaxNumMatches: 10_000,
                sequentialOverlap: 12,
                exhaustiveBlockSize: 25,
                threadCap: 8,
                colmapMaxImageSizeCap: nil,
                vggtAllowed: true
            )
        }
    }
}
