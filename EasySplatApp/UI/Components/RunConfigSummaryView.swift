import EasySplatCore
import SwiftUI

/// Compact run configuration badge shown on the viewer. Captures the
/// preset (mode + quality) and input kind so users coming back to a
/// finished project remember exactly what they asked for without
/// reopening project.json.
struct RunConfigSummaryView: View {
    let preset: PresetSpec
    let input: InputSpec
    @Environment(\.controlSize) private var controlSize

    var body: some View {
        HStack(spacing: 8) {
            badge(text: modeText, icon: "viewfinder", help: modeText)
            badge(text: qualityText, icon: "speedometer", help: qualityText)
            badge(text: inputText, icon: inputIcon, help: inputTooltip)
            Spacer(minLength: 0)
        }
    }

    private func badge(text: String, icon: String, help: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(text)
                .font(badgeFont)
        }
        .padding(.vertical, badgePadding.vertical)
        .padding(.horizontal, badgePadding.horizontal)
        .background(
            Capsule(style: .continuous).fill(Theme.surface)
        )
        .overlay(
            Capsule(style: .continuous).stroke(Theme.border)
        )
        .help(help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(help)
    }

    private var badgePadding: (vertical: CGFloat, horizontal: CGFloat) {
        switch controlSize {
        case .mini: return (1, 6)
        case .small: return (2, 7)
        default: return (3, 8)
        }
    }

    private var badgeFont: Font {
        switch controlSize {
        case .mini, .small: return .caption2.weight(.medium)
        default: return .caption.weight(.medium)
        }
    }

    private var modeText: String {
        switch preset.mode {
        case .object: return "Object"
        case .room: return "Room"
        }
    }

    private var qualityText: String {
        switch preset.quality {
        case .draft: return "Fast"
        case .standard: return "Balanced"
        case .ultra: return "Ultra"
        }
    }

    private var inputText: String {
        switch input {
        case .video(let files):
            return files.count == 1 ? "1 video" : "\(files.count) videos"
        case .photos:
            return "Photos folder"
        case .mixed(let videos, _):
            return "\(videos.count) video\(videos.count == 1 ? "" : "s") + photos"
        }
    }

    private var inputTooltip: String {
        Self.inputTooltip(for: input)
    }

    nonisolated static func inputTooltip(for input: InputSpec) -> String {
        switch input {
        case .video(let files):
            let names = files.map { URL(fileURLWithPath: $0).lastPathComponent }
            if names.count <= 3 {
                return names.joined(separator: ", ")
            }
            return names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
        case .photos(let folder):
            return URL(fileURLWithPath: folder).lastPathComponent
        case .mixed(let videos, let photosFolder):
            let folderName = URL(fileURLWithPath: photosFolder).lastPathComponent
            return "\(videos.count) video\(videos.count == 1 ? "" : "s") + \(folderName)"
        }
    }

    private var inputIcon: String {
        switch input {
        case .video: return "film"
        case .photos: return "photo.on.rectangle"
        case .mixed: return "rectangle.stack"
        }
    }
}
