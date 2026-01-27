import SwiftUI

struct DropZoneView: View {
    let title: String
    let subtitle: String
    let onDropURL: (URL) -> Void

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
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    DispatchQueue.main.async { onDropURL(url) }
                }
            }
            return true
        }
    }
}
