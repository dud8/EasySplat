import SwiftUI
import AppKit

struct LogDrawerView: View {
    let lines: [String]
    let detailsText: String?
    let copyText: String?
    var maxExpandedHeight: CGFloat = 180

    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let trimmedDetailsText = detailsText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasDetailsText = !trimmedDetailsText.isEmpty
        let rawCopyText = copyText ?? ""
        let hasCopyText = !rawCopyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        VStack(alignment: .leading, spacing: 8) {
            Button(action: toggleExpanded) {
                HStack {
                    Text(expanded ? "Hide Details" : "Show Details")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .animation(reduceMotion ? nil : Theme.Motion.hover, value: expanded)
                }
            }
            .buttonStyle(DisclosureButtonStyle())

            if expanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if hasDetailsText {
                            Text(trimmedDetailsText)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if !lines.isEmpty {
                            if hasDetailsText {
                                Divider()
                            }
                            ForEach(lines.indices, id: \.self) { index in
                                Text(lines[index])
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        if !hasDetailsText && lines.isEmpty {
                            Text("No details yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if hasCopyText {
                            HStack {
                                Spacer()
                                Button("Copy Details") {
                                    let pasteboard = NSPasteboard.general
                                    pasteboard.clearContents()
                                    pasteboard.setString(rawCopyText, forType: .string)
                                }
                                .buttonStyle(SecondaryButtonStyle())
                                .controlSize(.small)
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                .frame(maxHeight: maxExpandedHeight)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .fill(Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .stroke(Theme.border)
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func toggleExpanded() {
        if reduceMotion {
            expanded.toggle()
        } else {
            withAnimation(Theme.Motion.reveal) {
                expanded.toggle()
            }
        }
    }
}
