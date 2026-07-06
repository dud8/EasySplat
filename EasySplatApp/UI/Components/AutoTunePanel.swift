import EasySplatCore
import SwiftUI

/// Compact viewer panel that exposes the AutoTuner decisions captured for
/// the current project. Shown only when AutoTune actually ran (off when
/// EASYSPLAT_AUTOTUNE=0 or when the project predates the feature).
struct AutoTunePanel: View {
    let snapshot: AutoTuneSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Auto-tune")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Tier \(snapshot.tier)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 4) {
                row("Memory", value: String(format: "%.1f GB", snapshot.memoryGB))
                row("CPU cores", value: "\(snapshot.cpuCount) (cap \(snapshot.threadCap))")
                if let gpu = snapshot.gpuWorkingSetGB {
                    row("GPU working set", value: String(format: "%.1f GB", gpu))
                }
                row("VGGT max points", value: "\(snapshot.vggtMaxPoints)\(snapshot.vggtAllowed ? "" : " (disabled)")")
                row("MapAnything anchors", value: "\(snapshot.mapAnythingAnchorMaxViews) (window \(snapshot.mapAnythingWindowSize)/overlap \(snapshot.mapAnythingWindowOverlap))")
                row("COLMAP features", value: "\(snapshot.colmapMaxNumFeatures) / matches \(snapshot.colmapMaxNumMatches)")
                if let cap = snapshot.colmapMaxImageSizeCap {
                    row("COLMAP image cap", value: "\(cap) px")
                }
                row("Sequential overlap", value: "\(snapshot.colmapSequentialOverlap)")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.border)
        )
    }

    private func row(_ label: String, value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.leading)
            Text(value)
                .font(.caption.monospacedDigit())
                .gridColumnAlignment(.trailing)
        }
    }
}
