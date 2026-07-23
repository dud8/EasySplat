import AppKit
import Combine
import EasySplatCore
import OSLog
import UserNotifications

private let runStatusLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.easysplat.app",
    category: "RunStatus"
)

/// Surfaces long-run status outside the window: a progress bar on the Dock
/// icon while training runs, and a notification when a run ends while the
/// user isn't looking at EasySplat.
///
/// Outcomes are tracked from events observed *during* the active run — a
/// `.done` stage or a failure being published — never from end state alone.
/// Opening an already-finished project also toggles `isRunActive` without
/// running a pipeline, and stale `stage`/`lastError` values from an earlier
/// run must not produce a bogus notification.
///
/// Created only alongside the real main window. UNUserNotificationCenter
/// needs a host app bundle, so every notification call is additionally gated
/// on a bundle identity being present (a bare `swift run` executable has
/// none).
@MainActor
final class RunStatusPresenter {
    enum RunOutcome: Equatable {
        case finished
        case failed
        case stopped
    }

    private let model: AppModel
    /// Whether the user is already looking at the app: active, with the main
    /// window actually visible (not minimized, hidden, or fully covered).
    private let isUserAttending: () -> Bool
    private var cancellables: Set<AnyCancellable> = []
    private var wasRunActive = false
    private var sawCompletionDuringRun = false
    private var sawFailureDuringRun = false
    private var previousStage: PipelineStage?
    private var previousLastError: String?
    private var hasRequestedAuthorization = false
    private var lastDrawnPercent: Int?
    private let dockProgressView = DockProgressView()

    init(model: AppModel, isUserAttending: @escaping () -> Bool) {
        self.model = model
        self.isUserAttending = isUserAttending

        model.$isRunActive
            .removeDuplicates()
            .sink { [weak self] isActive in
                guard let self, isActive != wasRunActive else { return }
                wasRunActive = isActive
                if isActive {
                    runDidStart()
                } else {
                    runDidEnd()
                }
            }
            .store(in: &cancellables)

        model.$stage
            .combineLatest(model.$progress, model.$isRunActive)
            .sink { [weak self] stage, progress, isActive in
                guard let self else { return }
                if isActive, stage == .done, previousStage != .done {
                    sawCompletionDuringRun = true
                }
                previousStage = stage
                updateDockProgress(stage: stage, progress: progress, isRunActive: isActive)
            }
            .store(in: &cancellables)

        model.$lastError
            .sink { [weak self] lastError in
                guard let self else { return }
                if wasRunActive,
                   previousLastError == nil,
                   let lastError,
                   !lastError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    sawFailureDuringRun = true
                }
                previousLastError = lastError
            }
            .store(in: &cancellables)
    }

    // MARK: - Decisions

    nonisolated static func outcome(sawFailure: Bool, sawCompletion: Bool) -> RunOutcome {
        if sawFailure { return .failed }
        return sawCompletion ? .finished : .stopped
    }

    /// A notification only earns its interruption when the user isn't
    /// already looking at the app and the run ended on its own. A
    /// user-initiated stop is something the user already knows about.
    nonisolated static func shouldNotify(isUserAttending: Bool, outcome: RunOutcome) -> Bool {
        guard !isUserAttending else { return false }
        return outcome != .stopped
    }

    nonisolated static func notificationTitle(for outcome: RunOutcome) -> String? {
        switch outcome {
        case .finished: return "Splat ready"
        case .failed: return "Couldn’t finish this splat"
        case .stopped: return nil
        }
    }

    // MARK: - Run transitions

    private var notificationsAvailable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    private func runDidStart() {
        sawCompletionDuringRun = false
        sawFailureDuringRun = false
        guard notificationsAvailable, !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                runStatusLogger.error(
                    "Notification authorization failed: \(error.localizedDescription, privacy: .public)"
                )
            } else if !granted {
                runStatusLogger.notice("Notification authorization declined")
            }
        }
    }

    private func runDidEnd() {
        setDockProgress(nil)
        let outcome = Self.outcome(
            sawFailure: sawFailureDuringRun,
            sawCompletion: sawCompletionDuringRun
        )
        guard Self.shouldNotify(isUserAttending: isUserAttending(), outcome: outcome),
              let title = Self.notificationTitle(for: outcome),
              notificationsAvailable else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        if let projectTitle {
            content.body = projectTitle
        }
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                runStatusLogger.error(
                    "Notification delivery failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private var projectTitle: String? {
        guard let projectURL = model.currentProjectURL else { return nil }
        if let summary = model.projectSummaries.first(where: {
            ProjectSummary.hasSameLocation($0.url, projectURL)
        }) {
            return summary.title
        }
        return projectURL.deletingPathExtension().lastPathComponent
    }

    // MARK: - Dock progress

    private func updateDockProgress(stage: PipelineStage?, progress: Double?, isRunActive: Bool) {
        // Same honesty rule as the in-window bar: only stages with real
        // fractional progress get a determinate bar; the rest show nothing.
        let fraction = isRunActive
            ? ProcessingView.phaseProgress(stage: stage, progress: progress)
            : nil
        setDockProgress(fraction)
    }

    private func setDockProgress(_ fraction: Double?) {
        guard let fraction else {
            if lastDrawnPercent != nil {
                lastDrawnPercent = nil
                NSApp.dockTile.contentView = nil
                NSApp.dockTile.display()
            }
            return
        }
        let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
        guard percent != lastDrawnPercent else { return }
        lastDrawnPercent = percent
        dockProgressView.progress = Double(percent) / 100
        if NSApp.dockTile.contentView !== dockProgressView {
            NSApp.dockTile.contentView = dockProgressView
        }
        NSApp.dockTile.display()
    }
}

/// The app icon with a thin determinate bar near its bottom edge, in the
/// style of Dock download progress.
private final class DockProgressView: NSView {
    var progress: Double = 0

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)

        let barHeight = bounds.height * 0.07
        let horizontalInset = bounds.width * 0.14
        let track = NSRect(
            x: horizontalInset,
            y: bounds.height * 0.08,
            width: bounds.width - horizontalInset * 2,
            height: barHeight
        )
        let radius = barHeight / 2

        let trackPath = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)
        NSColor.white.withAlphaComponent(0.9).setFill()
        trackPath.fill()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        trackPath.lineWidth = 1
        trackPath.stroke()

        let clamped = min(max(progress, 0), 1)
        guard clamped > 0 else { return }
        let fill = NSRect(
            x: track.minX,
            y: track.minY,
            width: track.width * clamped,
            height: track.height
        )
        NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).addClip()
        NSColor.controlAccentColor.setFill()
        fill.fill()
    }
}
