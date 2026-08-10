#if os(macOS)

import AppKit
import EasySplatCore
import SplatIO
import SwiftUI

/// Viewing a splat that did not come from a project in this app.
///
/// The project viewer takes its scene bounds from the training manifest, which a splat
/// from anywhere else does not have. `SplatSceneBoundsCalculator` derives equivalent
/// bounds from the file itself — outlier-resistant and sampled, so a large file does not
/// stall the open — which is all the viewer actually needs to frame a scene.
enum StandaloneSplatLoadError: LocalizedError, Equatable {
    case noPlaceableGeometry

    var errorDescription: String? {
        switch self {
        case .noPlaceableGeometry:
            "This file has no gaussians the viewer can place."
        }
    }
}

enum StandaloneSplatLoad {
    /// Enough points to place the scene robustly without reading every gaussian of a
    /// multi-hundred-megabyte file before the window can appear.
    static let boundsSampleCount = 200_000

    static func sceneConfiguration(for url: URL) throws -> SplatViewerSceneConfiguration {
        guard let format = SplatSceneFormat.format(for: url) else {
            throw SplatSceneReaderFactory.Error.unsupportedFormat(
                url.pathExtension.lowercased()
            )
        }
        guard let bounds = try SplatSceneBoundsCalculator.compute(
            at: url,
            format: format,
            maximumSampleCount: boundsSampleCount
        ) else {
            // The viewer's own "missing authenticated scene bounds" is about a project
            // manifest, which says nothing useful about a file opened from disk.
            throw StandaloneSplatLoadError.noPlaceableGeometry
        }
        return SplatViewerSceneConfiguration(
            bounds: ViewerSceneBounds(
                center: SIMD3<Float>(
                    Float(bounds.center.x),
                    Float(bounds.center.y),
                    Float(bounds.center.z)
                ),
                radius: Float(bounds.radius)
            ),
            // A foreign splat carries no canonical orientation, so the viewer falls back
            // to its default framing rather than an upright the file cannot vouch for.
            openingDirection: nil,
            isViewOnlyFlipActive: false
        )
    }
}

struct StandaloneSplatViewerView: View {
    let splatURL: URL

    @State private var configuration: SplatViewerSceneConfiguration?
    @State private var failure: String?
    @State private var resetCameraToken = 0

    var body: some View {
        Group {
            if let failure {
                ContentUnavailableView {
                    Label("Can't open this splat", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                }
            } else if let configuration {
                SplatViewerView(
                    splatURL: splatURL,
                    resetCameraToken: resetCameraToken,
                    sceneConfiguration: configuration
                )
            } else {
                ProgressView("Reading \(splatURL.lastPathComponent)")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: splatURL) {
            configuration = nil
            failure = nil
            let url = splatURL
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try StandaloneSplatLoad.sceneConfiguration(for: url) }
            }.value
            guard !Task.isCancelled else { return }
            switch outcome {
            case .success(let value):
                configuration = value
            case .failure(let error):
                failure = error.localizedDescription
            }
        }
    }
}

/// Owns one window per opened splat so re-opening the same file focuses the window that
/// already shows it instead of stacking duplicates.
@MainActor
final class StandaloneSplatWindowPresenter: NSObject, NSWindowDelegate {
    static let shared = StandaloneSplatWindowPresenter()

    private var windows: [URL: NSWindow] = [:]
    /// One grant per open window. The reader loads and reloads the file for as
    /// long as the window is up, so the sandbox scope the picked URL carries has
    /// to stay open that whole time rather than only for this call.
    private var access: [URL: SecurityScopedAccess] = [:]

    func present(_ url: URL) {
        let key = url.standardizedFileURL
        if let existing = windows[key] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let claim = SecurityScopedAccess()
        claim.claim([url])

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = key.lastPathComponent
        window.subtitle = key.deletingLastPathComponent().path
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: StandaloneSplatViewerView(splatURL: key))
        window.center()
        window.delegate = self
        windows[key] = window
        access[key] = claim
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let closed = windows.filter { $0.value === window }.map(\.key)
        windows = windows.filter { $0.value !== window }
        for key in closed {
            access.removeValue(forKey: key)?.releaseAll()
        }
    }
}

#endif
