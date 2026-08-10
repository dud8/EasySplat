import Foundation
import SplatIO

/// What counts as a splat file, derived from what the reader can actually parse, so the
/// drop zone's explanation and the viewer's open path cannot drift apart.
enum SplatFileType {
    /// Containers ``SplatSceneReaderFactory`` can read.
    static var viewableExtensions: Set<String> { SplatSceneFormat.readableExtensions }

    /// Formats a user is likely to have on hand that this app cannot read. Recognised so
    /// a rejected drop can say why instead of falling back to generic advice.
    static let unreadableExtensions: Set<String> = ["spz", "ksplat"]

    static func isViewable(_ url: URL) -> Bool {
        viewableExtensions.contains(url.pathExtension.lowercased())
    }

    static func isSplat(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return viewableExtensions.contains(ext) || unreadableExtensions.contains(ext)
    }
}
