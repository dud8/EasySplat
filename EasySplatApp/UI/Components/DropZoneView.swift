import SwiftUI
import Foundation

struct DropZoneView: View {
    let title: String
    let subtitle: String
    let onDropURLs: ([URL]) -> Void

    @State private var isTargeted = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(isTargeted ? Theme.accent : Theme.border, style: StrokeStyle(lineWidth: 2, dash: [6]))
                .background(RoundedRectangle(cornerRadius: 18).fill(Theme.surface))
            VStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
        }
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
