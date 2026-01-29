import SwiftUI
import AppKit

struct LogDrawerView: View {
    let lines: [String]
    let detailsText: String?
    let copyText: String?

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
                        if let detailsText, !detailsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(detailsText)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if !lines.isEmpty {
                            if detailsText != nil {
                                Divider()
                            }
                            ForEach(lines.indices, id: \.self) { index in
                                Text(lines[index])
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        if (detailsText == nil || detailsText?.isEmpty == true) && lines.isEmpty {
                            Text("No details yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if let copyText, !copyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            HStack {
                                Spacer()
                                Button("Copy Details") {
                                    let pasteboard = NSPasteboard.general
                                    pasteboard.clearContents()
                                    pasteboard.setString(copyText, forType: .string)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.top, 4)
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
