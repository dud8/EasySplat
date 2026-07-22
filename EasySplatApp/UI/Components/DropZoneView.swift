import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    let title: String
    let subtitle: String
    let onChoose: () -> Void
    let onDropURLs: ([URL]) -> Void

    @State private var isTargeted = false
    nonisolated static let releaseInProgressTitle = "Release to add"
    nonisolated static let releaseInProgressSubtitle = "Videos, photos, or a folder"

    nonisolated static func displayTitle(restingTitle: String, isTargeted: Bool) -> String {
        isTargeted ? releaseInProgressTitle : restingTitle
    }

    nonisolated static func displaySubtitle(restingSubtitle: String, isTargeted: Bool) -> String {
        isTargeted ? releaseInProgressSubtitle : restingSubtitle
    }

    var body: some View {
        Button(action: onChoose) {
            VStack(spacing: Theme.Spacing.small) {
                Text(Self.displayTitle(restingTitle: title, isTargeted: isTargeted))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isTargeted ? Theme.accent : Color.primary)
                Text(Self.displaySubtitle(restingSubtitle: subtitle, isTargeted: isTargeted))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Theme.Spacing.large)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous)
                    .strokeBorder(isTargeted ? Theme.accent : Theme.border, lineWidth: isTargeted ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.standard, style: .continuous))
        }
        .buttonStyle(.plain)
        .onKeyPress(.return) {
            onChoose()
            return .handled
        }
        .accessibilityLabel(title)
        .accessibilityHint(subtitle)
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
