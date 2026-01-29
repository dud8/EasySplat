import SwiftUI
import Foundation
import UniformTypeIdentifiers

struct DropZoneView: View {
    let title: String
    let subtitle: String
    let onDropURLs: ([URL]) -> Void

    @State private var isTargeted = false
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.dropZone, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.dropZone, style: .continuous)
                        .fill(Theme.accent.opacity(hoverTint))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.dropZone, style: .continuous)
                        .strokeBorder(borderColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                )
                .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: shadowOffset)
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(reduceMotion ? nil : Theme.Motion.hover, value: isHovered)
        .animation(reduceMotion ? nil : Theme.Motion.hover, value: isTargeted)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            let group = DispatchGroup()
            let collector = URLCollector()
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url {
                        collector.append(url)
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                let urls = collector.urls()
                if !urls.isEmpty {
                    onDropURLs(urls)
                }
            }
            return !providers.isEmpty
        }
    }

    private var borderColor: Color {
        if isTargeted {
            return Theme.accent
        }
        if isHovered {
            return Theme.accent.opacity(0.45)
        }
        return Theme.border
    }

    private var hoverTint: Double {
        if isTargeted {
            return 0.08
        }
        if isHovered {
            return 0.05
        }
        return 0.0
    }

    private var shadowColor: Color {
        if isTargeted || isHovered {
            return Color.black.opacity(0.10)
        }
        return Color.clear
    }

    private var shadowRadius: CGFloat {
        (isTargeted || isHovered) ? 8 : 0
    }

    private var shadowOffset: CGFloat {
        (isTargeted || isHovered) ? 4 : 0
    }
}

private final class URLCollector: @unchecked Sendable {
    private var storage: [URL] = []
    private let lock = NSLock()

    func append(_ url: URL) {
        lock.lock()
        storage.append(url)
        lock.unlock()
    }

    func urls() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
