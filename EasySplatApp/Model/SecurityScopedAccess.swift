import Foundation

/// Keeps the sandbox's grant open for the files and folders the user picked.
///
/// A URL handed back by the file importer or by a drop carries a security scope,
/// and the sandbox refuses to read it — or anything below it — while that scope
/// is closed. The grant belongs to the URL the user chose, not to URLs derived
/// from it, so expanding a folder into its photos yields paths that stay readable
/// only for as long as the folder's own scope is held. Selection expands folders
/// straight away and the pipeline reads the files minutes later, which is why the
/// claim has to outlive the picker callback that produced it.
///
/// Outside the sandbox `startAccessingSecurityScopedResource()` reports false and
/// there is nothing to balance, so a claim costs nothing in the Developer ID lane.
final class SecurityScopedAccess {
    typealias Start = (URL) -> Bool
    typealias Stop = (URL) -> Void

    private let start: Start
    private let stop: Stop
    private var held: [URL] = []

    init(
        start: @escaping Start = { $0.startAccessingSecurityScopedResource() },
        stop: @escaping Stop = { $0.stopAccessingSecurityScopedResource() }
    ) {
        self.start = start
        self.stop = stop
    }

    deinit {
        for url in held { stop(url) }
    }

    /// The URLs whose scope this holder currently keeps open.
    var claimed: [URL] { held }

    /// Opens the scope of every file URL that carries one. The system counts
    /// repeated claims of the same URL, so each one taken here is balanced by
    /// exactly one release.
    func claim(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            if start(url) { held.append(url) }
        }
    }

    /// Drops every claim that no longer backs anything in `selection`. A claim
    /// on a folder backs the files below it, which is what a selection holds
    /// after it expands a chosen folder into paths of its own.
    func releaseRootsNotCovering(_ selection: [URL]) {
        guard !held.isEmpty else { return }
        let selected = Set(selection.map { $0.standardizedFileURL.path })
        var kept: [URL] = []
        for root in held {
            let path = root.standardizedFileURL.path
            let enclosing = path.hasSuffix("/") ? path : path + "/"
            if selected.contains(path)
                || selected.contains(where: { $0.hasPrefix(enclosing) }) {
                kept.append(root)
            } else {
                stop(root)
            }
        }
        held = kept
    }

    func releaseAll() {
        for url in held { stop(url) }
        held.removeAll()
    }
}
