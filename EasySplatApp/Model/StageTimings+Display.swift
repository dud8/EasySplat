import EasySplatCore
import Foundation

enum StageTimingDisplay {
    /// Human-friendly summary of total wall-clock time, e.g., "12m 30s".
    static func formatDuration(seconds: TimeInterval) -> String {
        let totalSeconds = Int(seconds.rounded())
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }
        if totalSeconds < 3600 {
            let minutes = totalSeconds / 60
            let rem = totalSeconds % 60
            return rem == 0 ? "\(minutes)m" : "\(minutes)m \(rem)s"
        }
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }
}
