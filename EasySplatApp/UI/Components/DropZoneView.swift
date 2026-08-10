import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    let title: String
    let subtitle: String
    let onChoose: () -> Void
    let onDropBatch: @MainActor @Sendable (DropURLLoadBatch) -> Void

    @State private var isTargeted = false
    nonisolated static let releaseInProgressTitle = "Release to add"
    nonisolated static let releaseInProgressSubtitle = "Videos, photos, folders, or datasets"

    nonisolated static func displayTitle(restingTitle: String, isTargeted: Bool) -> String {
        isTargeted ? releaseInProgressTitle : restingTitle
    }

    nonisolated static func displaySubtitle(restingSubtitle: String, isTargeted: Bool) -> String {
        isTargeted ? releaseInProgressSubtitle : restingSubtitle
    }

    var body: some View {
        Button(action: onChoose) {
            VStack(spacing: Theme.Spacing.small) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.title2)
                    .foregroundStyle(isTargeted ? Theme.accent : Color.secondary)
                    .accessibilityHidden(true)
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
                    .strokeBorder(
                        isTargeted ? Theme.accent : Theme.border,
                        style: StrokeStyle(
                            lineWidth: isTargeted ? 2 : 1,
                            dash: isTargeted ? [] : [5, 4]
                        )
                    )
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
            let accumulator = DropURLLoadAccumulator(
                expectedResultCount: providers.count,
                onCompletion: onDropBatch
            )
            for (index, provider) in providers.enumerated() {
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    let result = DropURLLoadResult(
                        index: index,
                        url: url,
                        providerFailed: error != nil
                    )
                    Task {
                        _ = await accumulator.append(result)
                    }
                }
            }
            return !providers.isEmpty
        }
    }
}

/// Records one terminal result for every provider. The actor makes a racing
/// provider callback unable to reorder input or invoke completion twice.
actor DropURLLoadAccumulator {
    private let expectedResultCount: Int
    private let onCompletion: (@MainActor @Sendable (DropURLLoadBatch) -> Void)?
    private var results: [Int: DropURLLoadResult] = [:]
    private var finished = false

    init(
        expectedResultCount: Int,
        onCompletion: (@MainActor @Sendable (DropURLLoadBatch) -> Void)? = nil
    ) {
        self.expectedResultCount = expectedResultCount
        self.onCompletion = onCompletion
    }

    func append(_ result: DropURLLoadResult) async -> DropURLLoadBatch? {
        guard !finished,
              result.index >= 0,
              result.index < expectedResultCount,
              results[result.index] == nil else {
            return nil
        }
        results[result.index] = result
        guard results.count == expectedResultCount else { return nil }
        finished = true
        let orderedResults = (0..<expectedResultCount).compactMap { results[$0] }
        let batch = DropURLLoadBatch(
            urls: orderedResults.compactMap(\.url),
            failedProviderCount: orderedResults.filter { $0.url == nil }.count
        )
        if let onCompletion {
            await onCompletion(batch)
        }
        return batch
    }
}
