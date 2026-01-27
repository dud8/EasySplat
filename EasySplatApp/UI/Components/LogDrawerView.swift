import SwiftUI

struct LogDrawerView: View {
    let lines: [String]

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: { expanded.toggle() }) {
                HStack {
                    Text(expanded ? "Hide Details" : "Show Details")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                }
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(lines.indices, id: \.self) { index in
                            Text(lines[index])
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 180)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
            }
        }
    }
}
