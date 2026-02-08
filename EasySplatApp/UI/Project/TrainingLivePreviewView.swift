import SwiftUI
import Foundation

struct TrainingLivePreviewView: View {
    let snapshotURL: URL
    var preferredHeight: CGFloat = 260
    var trainingProgressFraction: Double?
    @State private var state = TrainingLivePreviewState()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if state.hasDetectedSnapshot {
                ZStack {
                    if state.shouldCreateViewerSurface {
                        SplatViewerView(
                            splatURL: snapshotURL,
                            reloadToken: state.reloadToken,
                            showsLoadErrors: false,
                            onLoadStateChanged: handleLoadState,
                            overlayDensity: .compact
                        )
                        .opacity(state.hasRenderedPreview ? 1.0 : 0.001)
                        .allowsHitTesting(state.hasRenderedPreview)
                    }

                    if !state.hasRenderedPreview {
                        SnapshotPlaceholderView(
                            message: state.placeholderMessage,
                            detail: state.pollStatusLine
                        )
                    }
                }
                .frame(height: preferredHeight)
                .frame(maxWidth: .infinity)
            } else {
                SnapshotPlaceholderView(
                    message: "Waiting for preview…",
                    detail: state.pollStatusLine
                )
                    .frame(height: preferredHeight)
                    .frame(maxWidth: .infinity)
            }

            if let error = state.lastLoadError {
                LivePreviewErrorView(message: error)
            }
        }
        .task(id: snapshotURL) {
            await pollSnapshots()
        }
        .onChange(of: trainingProgressFraction) { _, newValue in
            state.updateTrainingProgress(newValue)
        }
    }

    @MainActor
    private func pollSnapshots() async {
        updateSnapshotState()
        while !Task.isCancelled {
            let nanos = UInt64(state.pollIntervalSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanos)
            updateSnapshotState()
        }
    }

    @MainActor
    private func updateSnapshotState() {
        let now = Date()
        state.updateTrainingProgress(trainingProgressFraction)
        state.recordPoll(at: now)
        let readiness = SnapshotPreviewReadiness.evaluate(url: snapshotURL)
        state.ingestFingerprint(
            SnapshotFingerprint(url: snapshotURL),
            now: now,
            isLoadable: readiness.isLoadable
        )
        if let message = readiness.message {
            state.ingestLoadState(.failed(message))
        }
    }

    @MainActor
    private func handleLoadState(_ loadState: SplatViewerLoadState) {
        state.ingestLoadState(loadState)
    }
}

struct TrainingLivePreviewState: Equatable {
    enum PollCadenceTier: String, Equatable {
        case early
        case mid
        case late

        var seconds: TimeInterval {
            switch self {
            case .early:
                return 5.0
            case .mid:
                return 10.0
            case .late:
                return 15.0
            }
        }

    }

    var hasDetectedSnapshot = false
    var hasRenderedPreview = false
    var isLoading = false
    var lastLoadError: String?
    var loadedFingerprint: SnapshotFingerprint?
    var pendingFingerprint: SnapshotFingerprint?
    var pendingSince: Date?
    var reloadToken = 0
    var pollCount = 0
    var lastPollAt: Date?
    var trainingProgressFraction: Double?

    var pollIntervalSeconds: TimeInterval {
        pollCadenceTier.seconds
    }

    var pollCadenceTier: PollCadenceTier {
        guard let trainingProgressFraction else {
            return .early
        }
        if trainingProgressFraction >= 0.80 {
            return .late
        }
        if trainingProgressFraction >= 0.33 {
            return .mid
        }
        return .early
    }

    var pollStatusLine: String {
        let interval = max(1, Int(pollIntervalSeconds.rounded()))
        return "Refreshes every \(interval)s."
    }

    var shouldCreateViewerSurface: Bool {
        hasRenderedPreview || reloadToken > 0
    }

    private var stabilityWindowSeconds: TimeInterval {
        hasRenderedPreview ? 1.5 : 2.0
    }

    var placeholderMessage: String {
        if lastLoadError != nil {
            return "Preview not ready yet."
        }
        if isLoading {
            return "Loading preview…"
        }
        return "Waiting for preview…"
    }

    mutating func ingestFingerprint(
        _ fingerprint: SnapshotFingerprint?,
        now: Date = Date(),
        isLoadable: Bool = true
    ) {
        guard let fingerprint else {
            if !hasRenderedPreview {
                hasDetectedSnapshot = false
            }
            pendingFingerprint = nil
            pendingSince = nil
            return
        }

        hasDetectedSnapshot = true
        guard isLoadable else {
            pendingFingerprint = nil
            pendingSince = nil
            isLoading = false
            return
        }
        if loadedFingerprint == fingerprint {
            pendingFingerprint = nil
            pendingSince = nil
            return
        }

        if pendingFingerprint != fingerprint {
            pendingFingerprint = fingerprint
            if shouldStartFirstLoadImmediately(fingerprint: fingerprint, now: now) {
                startLoading(fingerprint: fingerprint)
            } else {
                pendingSince = now
            }
            return
        }

        guard let pendingSince else {
            self.pendingSince = now
            return
        }

        guard now.timeIntervalSince(pendingSince) >= stabilityWindowSeconds else {
            return
        }

        startLoading(fingerprint: fingerprint)
    }

    mutating func ingestLoadState(_ loadState: SplatViewerLoadState) {
        switch loadState {
        case .loading:
            isLoading = true
        case .ready:
            isLoading = false
            hasRenderedPreview = true
            lastLoadError = nil
        case .failed(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmed.isEmpty ? "Preview loading failed." : trimmed
            let lowercased = normalized.lowercased()
            let resolvedMessage: String
            if lowercased.contains("unexpected file contents for a splat ply")
                || lowercased.contains("no property named \"nx\"")
                || lowercased.contains("unexpected point count discrepancy") {
                resolvedMessage = "Preview file is still updating; waiting for the next snapshot."
            } else {
                resolvedMessage = normalized
            }
            if !hasRenderedPreview, let loadedFingerprint {
                // Retry the same snapshot on the next poll if first-load failed transiently.
                pendingFingerprint = loadedFingerprint
                pendingSince = .distantPast
                self.loadedFingerprint = nil
            }
            if !isLoading, lastLoadError == resolvedMessage {
                return
            }
            isLoading = false
            lastLoadError = resolvedMessage
        }
    }

    mutating func recordPoll(at now: Date = Date()) {
        pollCount += 1
        lastPollAt = now
    }

    mutating func updateTrainingProgress(_ fraction: Double?) {
        guard let fraction else {
            trainingProgressFraction = nil
            return
        }
        trainingProgressFraction = min(max(fraction, 0.0), 1.0)
    }

    private func shouldStartFirstLoadImmediately(fingerprint: SnapshotFingerprint, now: Date) -> Bool {
        guard !hasRenderedPreview, loadedFingerprint == nil else { return false }
        let snapshotAge = now.timeIntervalSince(fingerprint.modifiedAt)
        return snapshotAge >= stabilityWindowSeconds
    }

    private mutating func startLoading(fingerprint: SnapshotFingerprint) {
        loadedFingerprint = fingerprint
        pendingFingerprint = nil
        pendingSince = nil
        reloadToken += 1
        isLoading = true
        lastLoadError = nil
    }
}

private enum SnapshotPreviewReadiness {
    case missing
    case loadable
    case updating(String)

    var isLoadable: Bool {
        if case .loadable = self {
            return true
        }
        return false
    }

    var message: String? {
        guard case .updating(let message) = self else { return nil }
        return message
    }

    private static let updatingMessage = "Preview file is still updating; waiting for the next snapshot."
    private static let endHeaderMarker = Data("end_header".utf8)

    static func evaluate(url: URL) -> SnapshotPreviewReadiness {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            guard let headerText = try readHeaderText(from: handle) else {
                return .updating(updatingMessage)
            }
            let headerOnly = headerText.lowercased()
            guard hasRequiredProperties(in: headerOnly) else {
                return .updating(updatingMessage)
            }
            return .loadable
        } catch {
            return .updating(updatingMessage)
        }
    }

    private static func hasRequiredProperties(in header: String) -> Bool {
        let hasPositionX = header.contains("property float x")
        let hasPositionY = header.contains("property float y")
        let hasPositionZ = header.contains("property float z")
        let hasColor = header.contains("property float f_dc_0")
            || header.contains("property uchar red")
            || header.contains("property float red")
        return hasPositionX && hasPositionY && hasPositionZ && hasColor
    }

    private static func readHeaderText(from handle: FileHandle) throws -> String? {
        var bytes = Data()
        let maxHeaderBytes = 256 * 1024
        let chunkSize = 16 * 1024

        while bytes.count < maxHeaderBytes {
            let remaining = maxHeaderBytes - bytes.count
            guard let chunk = try handle.read(upToCount: min(chunkSize, remaining)), !chunk.isEmpty else {
                return nil
            }
            bytes.append(chunk)

            guard let markerRange = bytes.range(of: endHeaderMarker) else { continue }
            var headerEndIndex = markerRange.upperBound
            if headerEndIndex < bytes.count, bytes[headerEndIndex] == 0x0D {
                headerEndIndex += 1
            }
            if headerEndIndex < bytes.count, bytes[headerEndIndex] == 0x0A {
                headerEndIndex += 1
            }
            let headerData = bytes[..<headerEndIndex]
            return String(decoding: headerData, as: UTF8.self)
        }
        return nil
    }
}

struct SnapshotFingerprint: Equatable {
    let modifiedAt: Date
    let fileSize: UInt64

    init(modifiedAt: Date, fileSize: UInt64) {
        self.modifiedAt = modifiedAt
        self.fileSize = fileSize
    }

    init?(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modifiedAt = attrs[.modificationDate] as? Date,
              let fileSize = attrs[.size] as? UInt64 else {
            return nil
        }
        self.init(modifiedAt: modifiedAt, fileSize: fileSize)
    }
}

private struct SnapshotPlaceholderView: View {
    let message: String
    var detail: String?

    var body: some View {
        VStack(spacing: 8) {
            ProgressView(message)
                .controlSize(.small)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.border)
        )
    }
}

private struct LivePreviewErrorView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preview not ready yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.border)
        )
    }
}

#if DEBUG
func test_isSnapshotPreviewLoadable(_ url: URL) -> Bool {
    SnapshotPreviewReadiness.evaluate(url: url).isLoadable
}
#endif
