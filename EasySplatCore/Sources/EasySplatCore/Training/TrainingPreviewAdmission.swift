import Foundation

/// Why a live training preview was withheld. Carried so the UI can say something
/// true instead of leaving the control silently inert.
public enum TrainingPreviewRefusal: String, Codable, Sendable, Equatable {
    case constrainedMemory = "constrained_memory"
    case insufficientSurplus = "insufficient_surplus"
    case memoryPressure = "memory_pressure"
    case invalidObservation = "invalid_observation"
}

public enum TrainingPreviewPermit: Sendable, Equatable {
    case granted
    case refused(TrainingPreviewRefusal)

    public var isGranted: Bool {
        if case .granted = self { return true }
        return false
    }

    public var refusal: TrainingPreviewRefusal? {
        if case .refused(let refusal) = self { return refusal }
        return nil
    }
}

/// Decides whether a run can afford to render its own training preview.
///
/// The trainer's budget is fixed before launch and a Metal allocation failure at
/// runtime aborts the run, so the preview is only ever spent out of headroom the
/// trainer was never given. It is never funded by shrinking that budget: a preview
/// is a convenience, and trading reconstruction quality for one is not a trade this
/// app should make. Every ambiguous signal refuses.
public enum TrainingPreviewAdmissionPolicy {
    private static let mebibyte: Int64 = 1_048_576

    /// Peak preview cost, not steady-state. The two-phase model swap holds the
    /// outgoing and incoming renderers at once, and the decode buffer overlaps both.
    /// Provisional until the preview-overhead measurement lane replaces it.
    public static let previewReserveBytes: Int64 = 384 * mebibyte

    /// Matches the trainer's own constrained tier: machines that already cap the
    /// trainer have nothing left to lend a preview.
    private static let constrainedMemoryBoundary: UInt64 = 33 * 1_073_741_824 / 2

    public static func evaluate(
        admission: TrainingResourceAdmission,
        admittedTrainerBytes: Int64,
        physicalMemoryBytes: UInt64,
        memoryPressure: MemoryPressureState
    ) -> TrainingPreviewPermit {
        guard TrainingMemoryBudget.isValid(admission),
              admittedTrainerBytes > 0,
              admission.allowedTrainerBytes <= UInt64(Int64.max) else {
            return .refused(.invalidObservation)
        }
        guard physicalMemoryBytes > constrainedMemoryBoundary else {
            return .refused(.constrainedMemory)
        }
        // Anything other than a positively observed normal reading fails closed:
        // `.unknown` means observation failed, and inferring calm from silence is
        // exactly how a preview ends up causing an exit-71 mid-run.
        guard memoryPressure == .normal else {
            return .refused(.memoryPressure)
        }
        let surplus = Int64(admission.allowedTrainerBytes) - admittedTrainerBytes
        guard surplus >= previewReserveBytes else {
            return .refused(.insufficientSurplus)
        }
        return .granted
    }
}
