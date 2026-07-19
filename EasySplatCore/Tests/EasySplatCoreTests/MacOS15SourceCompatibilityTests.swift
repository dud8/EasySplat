import Darwin
import Foundation
import XCTest

final class MacOS15SourceCompatibilityTests: XCTestCase {
    func testProductionSwiftSourcesUseOnlyMacOS15FilesystemIdentifiers() throws {
        let repository = try repositoryRoot()
        let sourceRoots = [
            repository.appendingPathComponent("EasySplatCore/Sources", isDirectory: true),
            repository.appendingPathComponent("EasySplatApp", isDirectory: true),
            repository.appendingPathComponent("Tools", isDirectory: true),
        ]

        let offenses = try compatibilityOffenses(
            in: sourceRoots,
            relativeTo: repository
        )

        XCTAssertTrue(
            offenses.isEmpty,
            "Production Swift sources require unsupported filesystem identifiers:\n\(offenses.joined(separator: "\n"))"
        )
    }

    func testScannerRejectsSymlinkedSwiftSource() throws {
        let repository = try TestFileBuilder.makeTempDir()
        defer { try? FileManager.default.removeItem(at: repository) }
        let sources = repository.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let external = repository.appendingPathComponent("External.swift")
        try "let flags = O_UNIQUE\n".write(to: external, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: sources.appendingPathComponent("Linked.swift"),
            withDestinationURL: external
        )

        XCTAssertEqual(
            try compatibilityOffenses(in: [sources], relativeTo: repository),
            ["Sources/Linked.swift: symbolic link"]
        )
    }

    private func compatibilityOffenses(
        in sourceRoots: [URL],
        relativeTo repository: URL
    ) throws -> [String] {
        let canonicalRepository = URL(fileURLWithPath: try canonicalPath(of: repository))
        let excludedComponents: Set<String> = [
            ".build",
            ".swiftpm",
            "DerivedData",
            "Tests",
            "build",
        ]
        let forbiddenIdentifiers = [
            "AT_RESOLVE_BENEATH",
            "AT_UNIQUE",
            "O_RESOLVE_BENEATH",
            "O_UNIQUE",
            "RENAME_RESOLVE_BENEATH",
        ]

        var offenses: [String] = []
        var swiftSources: [URL] = []
        for sourceRoot in sourceRoots {
            guard let enumerator = FileManager.default.enumerator(
                at: sourceRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: []
            ) else {
                XCTFail("Could not enumerate \(sourceRoot.path)")
                continue
            }
            for case let candidate as URL in enumerator {
                let relativeComponents = candidate.pathComponents.dropFirst(
                    canonicalRepository.pathComponents.count
                )
                if relativeComponents.contains(where: excludedComponents.contains) {
                    enumerator.skipDescendants()
                    continue
                }
                let values = try candidate.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    let relativePath = candidate.path.dropFirst(canonicalRepository.path.count + 1)
                    offenses.append("\(relativePath): symbolic link")
                    continue
                }
                guard candidate.pathExtension == "swift", values.isRegularFile == true else {
                    continue
                }
                swiftSources.append(candidate)
            }
        }

        for source in swiftSources.sorted(by: { $0.path < $1.path }) {
            let contents = try String(contentsOf: source, encoding: .utf8)
            let identifiers = Set(contents.split(whereSeparator: {
                !$0.isLetter && !$0.isNumber && $0 != "_"
            }))
            let relativePath = source.path.dropFirst(canonicalRepository.path.count + 1)
            for forbidden in forbiddenIdentifiers where identifiers.contains(Substring(forbidden)) {
                offenses.append("\(relativePath): \(forbidden)")
            }
        }

        return offenses.sorted()
    }

    private func canonicalPath(of url: URL) throws -> String {
        guard let resolved = url.path.withCString({ realpath($0, nil) }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func repositoryRoot() throws -> URL {
        var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while candidate.path != "/" {
            let package = candidate.appendingPathComponent("Package.swift")
            let core = candidate.appendingPathComponent("EasySplatCore", isDirectory: true)
            if FileManager.default.fileExists(atPath: package.path),
               FileManager.default.fileExists(atPath: core.path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        throw NSError(
            domain: "MacOS15SourceCompatibilityTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate the EasySplat repository"]
        )
    }
}
