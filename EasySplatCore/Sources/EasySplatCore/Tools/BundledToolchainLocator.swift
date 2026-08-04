import Foundation

/// Where a run's toolchain binaries come from.
///
/// Release builds execute only the helpers sealed inside the signed app bundle.
/// The development override exists so `swift run` and benchmark harnesses can
/// point at a locally built tree; callers must gate it behind
/// development-only configuration.
public enum ToolchainSource: Sendable, Equatable {
    case appBundle(root: URL, dataRoot: URL)
    case developmentOverride(root: URL)

    public var root: URL {
        switch self {
        case .appBundle(let root, _): return root
        case .developmentOverride(let root): return root
        }
    }

    /// Non-executable payload root: `default.metallib`, `msplat/`,
    /// `provenance/`, `supply-chain/`. Code signing rejects plain files under
    /// `Contents/Helpers`, so the bundle keeps them in sealed resources while a
    /// development tree keeps the historical single-root layout.
    public var dataRoot: URL {
        switch self {
        case .appBundle(_, let dataRoot): return dataRoot
        case .developmentOverride(let root): return root
        }
    }

    public var metallib: URL {
        switch self {
        case .appBundle(_, let dataRoot):
            return dataRoot.appendingPathComponent("default.metallib")
        case .developmentOverride(let root):
            return root.appendingPathComponent("bin/default.metallib")
        }
    }

    public var isDevelopmentOverride: Bool {
        if case .developmentOverride = self { return true }
        return false
    }
}

/// Resolves the toolchain shipped inside the running app bundle, or a
/// development override tree when one is supplied.
///
/// The locator never falls back: a bundle build that is missing its helpers is
/// broken and must say so, not go looking elsewhere.
public struct BundledToolchainLocator: Sendable {
    public static let helpersRelativePath = "Contents/Helpers"
    public static let dataRelativePath = "Contents/Resources/Toolchain"

    private let bundleURL: URL
    private let developmentOverrideRoot: URL?

    public init(
        bundleURL: URL = Bundle.main.bundleURL,
        developmentOverrideRoot: URL? = nil
    ) {
        self.bundleURL = bundleURL
        self.developmentOverrideRoot = developmentOverrideRoot
    }

    public func locate() throws -> ToolchainSource {
        if let developmentOverrideRoot {
            return .developmentOverride(root: developmentOverrideRoot)
        }
        guard bundleURL.pathExtension == "app" else {
            throw ToolchainManager.ToolchainError.invalidToolchain(
                "This EasySplat build is not running from an app bundle and has no built-in tools."
            )
        }
        let root = bundleURL.appendingPathComponent(Self.helpersRelativePath, isDirectory: true)
        let dataRoot = bundleURL.appendingPathComponent(Self.dataRelativePath, isDirectory: true)
        try requirePlainDirectory(at: root)
        try requirePlainDirectory(at: dataRoot)
        let colmap = root.appendingPathComponent("bin/colmap")
        guard isSingleLinkRegularFile(at: colmap),
              FileManager.default.isExecutableFile(atPath: colmap.path) else {
            throw ToolchainManager.ToolchainError.invalidToolchain(
                "This EasySplat build is missing its built-in tools. Reinstall EasySplat."
            )
        }
        return .appBundle(root: root, dataRoot: dataRoot)
    }

    private func requirePlainDirectory(at url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR else {
            throw ToolchainManager.ToolchainError.invalidToolchain(
                "This EasySplat build is missing its built-in tools. Reinstall EasySplat."
            )
        }
    }

    private func isSingleLinkRegularFile(at url: URL) -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return false }
        return (status.st_mode & S_IFMT) == S_IFREG && status.st_nlink == 1
    }
}
