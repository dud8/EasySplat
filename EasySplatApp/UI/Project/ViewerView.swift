import SwiftUI
import AppKit
import EasySplatCore

struct ViewerView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Your splat is ready")
                .font(.title2.weight(.semibold))

            if let plyURL = model.outputPlyURL {
                Text(plyURL.lastPathComponent)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                SplatViewerView(splatURL: plyURL)
                    .frame(height: 360)
                    .frame(maxWidth: .infinity)
                HStack(spacing: 12) {
                    Button("Share…") {
                        model.shareCurrentSplat()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(model.isShareSheetActive)

                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([plyURL])
                    }
                    .buttonStyle(SecondaryButtonStyle())

                    if let brush = model.toolchainPaths?.brush {
                        Button("Open in Brush") {
                            openInBrush(brushPath: brush, splatURL: plyURL)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }

                if let shareStatus = model.shareStatusMessage {
                    Label(shareStatus, systemImage: shareStatusSymbol(for: shareStatus))
                        .font(.caption)
                        .foregroundStyle(shareStatusColor(for: shareStatus))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Share status")
                        .accessibilityValue(shareStatus)
                }
                if let shareSummary = model.shareSummaryText {
                    Text(shareSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("No output found yet.")
                    .foregroundStyle(.secondary)
            }

            Button("Start Another") {
                model.viewState = .home
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(32)
    }

    private func openInBrush(brushPath: URL, splatURL: URL) {
        let process = Process()
        process.executableURL = brushPath
        process.arguments = ["--with-viewer", splatURL.path]
        try? process.run()
    }

    private func shareStatusSymbol(for status: String) -> String {
        if model.shareStatusIsError {
            return "exclamationmark.triangle.fill"
        }
        let lower = status.lowercased()
        if lower.contains("sharing") || lower.contains("opened") {
            return "square.and.arrow.up.fill"
        }
        if lower.contains("canceled") {
            return "minus.circle.fill"
        }
        return "checkmark.circle.fill"
    }

    private func shareStatusColor(for status: String) -> Color {
        if model.shareStatusIsError {
            return .red
        }
        let lower = status.lowercased()
        if lower.hasPrefix("shared via") {
            return Theme.success
        }
        return Theme.subtle
    }
}
