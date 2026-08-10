import Foundation
import Security

/// How far a toolchain's build receipts can be trusted to describe the bytes on
/// disk.
///
/// Receipts record the executable a build produced. Distribution signing rewrites
/// that executable afterwards, so inside a signed bundle the receipt digest and
/// the shipped bytes belong to different domains and comparing them is a
/// guaranteed failure rather than a check. The app's own signature covers the
/// helpers there. An unsigned tree has no such cover, so the digests must agree.
///
/// `signedAppBundle` is therefore only sound once the seal has actually been
/// checked: the locator verifies the bundle's static code signature, including
/// nested code, before it hands back that policy. Without that step the relaxed
/// comparison would trust any `.app`-shaped directory.
public enum ToolchainIntegrityPolicy: String, Sendable, Equatable, Codable {
    case signedAppBundle
    case unsignedDevelopmentTree
}

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

    public var integrityPolicy: ToolchainIntegrityPolicy {
        switch self {
        case .appBundle: return .signedAppBundle
        case .developmentOverride: return .unsignedDevelopmentTree
        }
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
    private let validateSignature: @Sendable (URL) throws -> Void

    public init(
        bundleURL: URL = Bundle.main.bundleURL,
        developmentOverrideRoot: URL? = nil
    ) {
        self.init(
            bundleURL: bundleURL,
            developmentOverrideRoot: developmentOverrideRoot,
            validateSignature: Self.requireIntactCodeSignature
        )
    }

    /// Module-internal seam for tests whose fixture helpers are scripts rather
    /// than Mach-Os and so cannot carry a signature. The public initializer
    /// always installs the real check, so no caller outside this module can
    /// reach a locator that skips it.
    init(
        bundleURL: URL,
        developmentOverrideRoot: URL?,
        validateSignature: @escaping @Sendable (URL) throws -> Void
    ) {
        self.bundleURL = bundleURL
        self.developmentOverrideRoot = developmentOverrideRoot
        self.validateSignature = validateSignature
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
        try validateSignature(bundleURL)
        return .appBundle(root: root, dataRoot: dataRoot)
    }

    /// Confirms the bundle still matches what its signer sealed.
    ///
    /// The bundled tools are trusted because the app's signature covers them, so
    /// that signature has to be checked rather than assumed. This validates the
    /// seal, not the signing authority: an ad-hoc developer build passes, while
    /// any bundle whose helpers were replaced after signing fails. Gatekeeper
    /// gates the first launch; nothing re-checks a bundle a local attacker edits
    /// afterwards, and the helpers run as child processes that macOS does not
    /// verify on the app's behalf.
    static func requireIntactCodeSignature(at bundleURL: URL) throws {
        var staticCode: SecStaticCode?
        let created = SecStaticCodeCreateWithPath(
            bundleURL as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        )
        guard created == errSecSuccess, let staticCode else {
            throw ToolchainManager.ToolchainError.invalidToolchain(
                "This EasySplat build is not signed. Reinstall EasySplat."
            )
        }
        let flags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures
                | kSecCSCheckNestedCode
                | kSecCSStrictValidate
        )
        let status = SecStaticCodeCheckValidity(staticCode, flags, nil)
        guard status == errSecSuccess else {
            throw ToolchainManager.ToolchainError.invalidToolchain(
                "This EasySplat build has been modified since it was signed. Reinstall EasySplat."
            )
        }
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
