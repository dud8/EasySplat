import Foundation

/// Coarse categorization of a project's `lastError` string. The pipeline emits
/// human-readable messages today but no structured error code, so this enum
/// pattern-matches the message and surfaces an actionable hint for the user.
/// Adding more cases over time is intentional — false negatives just fall
/// through to `.unknown`, which still renders the raw message.
public enum ProjectFailureCategory: String, Sendable {
    case lowQualityReconstruction
    case insufficientInputImages
    case toolchainUnavailable
    case diskSpace
    case sandboxOrPermission
    case canceledByUser
    case unknown

    /// Inspect the project's persisted `lastError` and infer a category.
    /// Returns `.unknown` when the message is empty or does not match any
    /// known pattern so callers can decide whether to suppress the hint.
    /// Ordering matters: a single message can mention several concepts
    /// (e.g., "Failed to download toolchain. No space left on device.") and
    /// the most actionable category — disk space, permissions — should win
    /// over the more generic network/toolchain bucket.
    public static func classify(message: String?) -> ProjectFailureCategory {
        guard let raw = message?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .unknown
        }
        let lower = raw.lowercased()

        // Most actionable signals first: if disk is full or permissions are
        // wrong, fix that before chasing a toolchain or quality dialog.
        if lower.contains("disk full") || lower.contains("no space left") || lower.contains("device is full") {
            return .diskSpace
        }
        if lower.contains("permission denied")
            || lower.contains("operation not permitted")
            || lower.contains("not permitted")
            || lower.contains("sandbox") {
            return .sandboxOrPermission
        }
        if lower.contains("canceled") || lower.contains("cancelled") || lower.contains("user canceled") {
            return .canceledByUser
        }
        if lower.contains("couldn't get a stable camera solve")
            || lower.contains("low-quality reconstruction")
            || lower.contains("below the quality bar") {
            return .lowQualityReconstruction
        }
        // Match the live user message produced by PipelineRunner+Recovery for
        // the insufficient-input path verbatim, plus a few synonymous shapes
        // that show up in dev logs or future error paths.
        if lower.contains("at least two usable photos")
            || lower.contains("insufficient input")
            || lower.contains("no usable photos")
            || lower.contains("not enough usable frames")
            || lower.contains("expected at least") {
            return .insufficientInputImages
        }
        if lower.contains("manifest")
            || lower.contains("toolchain")
            || lower.contains("download") {
            return .toolchainUnavailable
        }
        return .unknown
    }

    /// Short, plain-language user hint. Returns nil when no useful suggestion
    /// applies — callers should fall back to showing the raw error.
    public var hint: String? {
        switch self {
        case .lowQualityReconstruction:
            return "Try a slower capture with more overlap. The Balanced or Ultra preset selects more frames."
        case .insufficientInputImages:
            return "EasySplat needs at least a dozen usable frames. Capture more views or use a longer clip."
        case .toolchainUnavailable:
            return "Confirm the toolchain manifest URL is reachable. Network issues or an unreachable server are the usual cause."
        case .diskSpace:
            return "Free up disk space and try again. Each run can produce several gigabytes of intermediate output."
        case .sandboxOrPermission:
            return "macOS denied a file or folder. Right-click the input folder, choose Get Info, and grant access."
        case .canceledByUser:
            return "The run was canceled. Open the project to resume from the last good stage."
        case .unknown:
            // No specific category matched — point the user at the diagnostic
            // bundle so they can attach concrete logs to a bug report.
            return "Use Copy Diagnostics from the project's context menu to attach the run's logs to a bug report."
        }
    }

    /// SF Symbol name the UI can render alongside the hint. Picked so the
    /// icon hints at severity (info / warning / error) without needing a
    /// separate color attribute.
    public var systemImageName: String {
        switch self {
        case .lowQualityReconstruction:
            return "scope"
        case .insufficientInputImages:
            return "photo.stack"
        case .toolchainUnavailable:
            return "network.slash"
        case .diskSpace:
            return "externaldrive.badge.exclamationmark"
        case .sandboxOrPermission:
            return "lock.slash"
        case .canceledByUser:
            return "stop.circle"
        case .unknown:
            return "exclamationmark.triangle"
        }
    }
}
