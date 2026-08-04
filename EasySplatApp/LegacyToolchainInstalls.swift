import Foundation

/// Reclaims the multi-gigabyte toolchain tree earlier builds downloaded into
/// Application Support. Tools now ship inside the app, so the tree is dead
/// weight on any Mac that ran one of those builds.
enum LegacyToolchainInstalls {
    static let completionKey = "didRemoveLegacyToolchainInstalls"

    static func removeOnce(
        developmentOverrideRoot: URL?,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        guard !defaults.bool(forKey: completionKey) else { return }
        guard let base = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return }
        let installs = base.appendingPathComponent("EasySplat/Toolchains", isDirectory: true)

        // A development tree living inside the old location is in use, not stale.
        // Symbolic links have to be resolved: standardizing alone leaves a link
        // that points into the tree looking like an unrelated path.
        if let developmentOverrideRoot {
            let root = installs.resolvingSymlinksInPath().standardizedFileURL.path
            let override = developmentOverrideRoot.resolvingSymlinksInPath()
                .standardizedFileURL.path
            guard override != root, !override.hasPrefix(root + "/") else { return }
        }

        try? fileManager.removeItem(at: installs)
        defaults.set(true, forKey: completionKey)
    }
}
