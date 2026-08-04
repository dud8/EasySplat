import XCTest
@testable import EasySplatApp

/// Redirects the Application Support lookup so the removal never sees the real one.
private final class RedirectedFileManager: FileManager {
    let base: URL

    init(base: URL) {
        self.base = base
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        guard directory == .applicationSupportDirectory else {
            return super.urls(for: directory, in: domainMask)
        }
        return [base]
    }
}

final class LegacyToolchainInstallsTests: XCTestCase {
    private var root: URL!
    private var installs: URL!
    private var fileManager: RedirectedFileManager!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        installs = root.appendingPathComponent("EasySplat/Toolchains", isDirectory: true)
        try FileManager.default.createDirectory(
            at: installs.appendingPathComponent("3.0.0/bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("colmap".utf8).write(
            to: installs.appendingPathComponent("3.0.0/bin/colmap")
        )
        fileManager = RedirectedFileManager(base: root)
        suiteName = "LegacyToolchainInstallsTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    func testRemovesTheLegacyTreeAndRecordsCompletion() {
        LegacyToolchainInstalls.removeOnce(
            developmentOverrideRoot: nil,
            defaults: defaults,
            fileManager: fileManager
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: installs.path))
        XCTAssertTrue(defaults.bool(forKey: LegacyToolchainInstalls.completionKey))
    }

    func testDoesNotRunTwice() throws {
        defaults.set(true, forKey: LegacyToolchainInstalls.completionKey)

        LegacyToolchainInstalls.removeOnce(
            developmentOverrideRoot: nil,
            defaults: defaults,
            fileManager: fileManager
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: installs.path))
    }

    func testKeepsATreeADevelopmentOverrideIsUsing() {
        LegacyToolchainInstalls.removeOnce(
            developmentOverrideRoot: installs.appendingPathComponent("3.0.0", isDirectory: true),
            defaults: defaults,
            fileManager: fileManager
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: installs.path))
        XCTAssertFalse(defaults.bool(forKey: LegacyToolchainInstalls.completionKey))
    }

    func testRemovesWhenTheDevelopmentOverrideLivesElsewhere() throws {
        let elsewhere = root.appendingPathComponent("Toolchains-out", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)

        LegacyToolchainInstalls.removeOnce(
            developmentOverrideRoot: elsewhere,
            defaults: defaults,
            fileManager: fileManager
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: installs.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.path))
    }

    /// A prefix comparison that forgets the separator would treat this sibling as
    /// living inside the tree and skip a removal it should perform.
    func testRemovesWhenTheOverridePathOnlySharesAPrefix() throws {
        let sibling = root.appendingPathComponent("EasySplat/ToolchainsLocal", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        LegacyToolchainInstalls.removeOnce(
            developmentOverrideRoot: sibling,
            defaults: defaults,
            fileManager: fileManager
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: installs.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    }
}
