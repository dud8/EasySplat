import Darwin
import EasySplatCore
import Foundation
import XCTest
@testable import EasySplatReleaseVerifierCore

final class PackagedProjectArgumentsTests: XCTestCase {
    func testRequiresCanonicalManifestAndRootInputPair() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("capture.mov")
        try Data("video".utf8).write(to: input)

        let manifest = root.appendingPathComponent("inputs.json")
        try Data("{}".utf8).write(to: manifest)
        let parsed = try PackagedProjectArguments.parse(
            arguments(root: root) + [
                "--input-manifest", manifest.path,
                "--input-root", root.path,
            ]
        )
        XCTAssertEqual(parsed.inputManifestURL, manifest)
        XCTAssertEqual(parsed.inputRootURL, root)

        for invalid in [
            arguments(root: root),
            arguments(root: root) + ["--input", input.path],
            arguments(root: root) + ["--input-manifest", manifest.path],
            arguments(root: root) + ["--input-root", root.path],
            arguments(root: root) + [
                "--input", input.path,
                "--input-manifest", manifest.path,
                "--input-root", root.path,
            ],
        ] {
            XCTAssertThrowsError(try PackagedProjectArguments.parse(invalid))
        }
    }

    func testResolvesCanonicalSchemaOneMultiVideoMixedAndPhotoOnlyManifests() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let videos = root.appendingPathComponent("Videos", isDirectory: true)
        let photos = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let first = videos.appendingPathComponent("first.mov")
        let second = videos.appendingPathComponent("second.mov")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)

        let cases: [(String, FinishedProjectExpectedInput)] = [
            (
                #"{"photoFolder":null,"schemaVersion":1,"videos":["Videos/first.mov","Videos/second.mov"]}"#,
                .videoFiles([first, second])
            ),
            (
                #"{"photoFolder":"Photos","schemaVersion":1,"videos":["Videos/first.mov","Videos/second.mov"]}"#,
                .mixed(videoFiles: [first, second], photoFolder: photos)
            ),
            (
                #"{"photoFolder":"Photos","schemaVersion":1,"videos":[]}"#,
                .photoFolder(photos)
            ),
        ]
        for (index, item) in cases.enumerated() {
            let manifest = root.appendingPathComponent("manifest-\(index).json")
            let data = Data(item.0.utf8)
            try data.write(to: manifest)
            let parsed = try PackagedProjectArguments.parse(
                arguments(root: root) + [
                    "--input-manifest", manifest.path,
                    "--input-root", root.path,
                ]
            )
            let resolved = try parsed.resolveInput()
            XCTAssertEqual(resolved.expectedInput, item.1)
            XCTAssertEqual(resolved.boundaryURL, root)
            XCTAssertEqual(resolved.manifestData, data)
        }
    }

    func testRejectsUnsafeAmbiguousAndNoncanonicalManifestEntries() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let unsafeVideos = [
            "../outside.mov",
            "/absolute.mov",
            "nested//clip.mov",
            "nested/./clip.mov",
            "nested/../clip.mov",
            "nested\\clip.mov",
            "Cafe\u{301}.mov",
            "clip\u{7f}.mov",
        ]
        for (index, path) in unsafeVideos.enumerated() {
            let manifest = root.appendingPathComponent("unsafe-\(index).json")
            let object: [String: Any] = [
                "photoFolder": NSNull(),
                "schemaVersion": 1,
                "videos": [path],
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try data.write(to: manifest)
            XCTAssertThrowsError(
                try manifestArguments(root: root, manifest: manifest).resolveInput()
            )
        }

        let ambiguous = root.appendingPathComponent("ambiguous.json")
        try Data(
            #"{"photoFolder":null,"schemaVersion":1,"videos":["Clip.mov","clip.mov"]}"#.utf8
        ).write(to: ambiguous)
        XCTAssertThrowsError(
            try manifestArguments(root: root, manifest: ambiguous).resolveInput()
        )

        let extraKey = root.appendingPathComponent("extra.json")
        try Data(
            #"{"extra":true,"photoFolder":null,"schemaVersion":1,"videos":["clip.mov"]}"#.utf8
        ).write(to: extraKey)
        XCTAssertThrowsError(
            try manifestArguments(root: root, manifest: extraKey).resolveInput()
        )

        let noncanonicalWhitespace = root.appendingPathComponent("whitespace.json")
        try Data(
            (#"{"photoFolder":null,"schemaVersion":1,"videos":["clip.mov"]}"# + "\n").utf8
        ).write(to: noncanonicalWhitespace)
        XCTAssertThrowsError(
            try manifestArguments(root: root, manifest: noncanonicalWhitespace).resolveInput()
        )

        for (index, videos) in [
            ["Clip.mov", "clip.mov"],
            ["Café.mov", "Cafe.mov"],
            ["Ａ.mov", "A.mov"],
        ].enumerated() {
            let manifest = root.appendingPathComponent("equivalent-\(index).json")
            try canonicalManifest(videos: videos, photoFolder: nil).write(to: manifest)
            XCTAssertThrowsError(
                try manifestArguments(root: root, manifest: manifest).resolveInput()
            )
        }
    }

    func testRejectsEmptyAndOverLimitManifestSelections() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let empty = root.appendingPathComponent("empty.json")
        try canonicalManifest(videos: [], photoFolder: nil).write(to: empty)
        XCTAssertThrowsError(
            try manifestArguments(root: root, manifest: empty).resolveInput()
        )

        let overLimit = root.appendingPathComponent("over-limit.json")
        let videos = (0...64).map { "video-\($0).mov" }
        try canonicalManifest(videos: videos, photoFolder: nil).write(to: overLimit)
        XCTAssertThrowsError(
            try manifestArguments(root: root, manifest: overLimit).resolveInput()
        )
    }

    func testRejectsMissingSymlinkHardlinkAndDuplicateIdentityEntries() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.mov")
        let hardlink = root.appendingPathComponent("hardlink.mov")
        let symlink = root.appendingPathComponent("symlink.mov")
        try Data("video".utf8).write(to: original)
        XCTAssertEqual(link(original.path, hardlink.path), 0)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: original)

        for (index, videos) in [
            ["missing.mov"],
            ["symlink.mov"],
            ["original.mov"],
            ["original.mov", "hardlink.mov"],
        ].enumerated() {
            let manifest = root.appendingPathComponent("identity-\(index).json")
            let object: [String: Any] = [
                "photoFolder": NSNull(),
                "schemaVersion": 1,
                "videos": videos,
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try data.write(to: manifest)
            XCTAssertThrowsError(
                try manifestArguments(root: root, manifest: manifest).resolveInput()
            )
        }
    }

    func testRejectsLinkedRootsAndPhotoFolders() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = root.appendingPathComponent("photos.json")
        try canonicalManifest(videos: [], photoFolder: "Photos").write(to: manifest)

        let linkedRoot = root.appendingPathComponent("LinkedRoot", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
        XCTAssertThrowsError(
            try manifestArguments(root: linkedRoot, manifest: manifest).resolveInput()
        )

        let actualPhotos = root.appendingPathComponent("ActualPhotos", isDirectory: true)
        let linkedPhotos = root.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(
            at: actualPhotos,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: linkedPhotos,
            withDestinationURL: actualPhotos
        )
        XCTAssertThrowsError(
            try manifestArguments(root: root, manifest: manifest).resolveInput()
        )
    }

    func testRejectsHardlinkedAndOversizedManifestFiles() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = root.appendingPathComponent("manifest.json")
        let manifestLink = root.appendingPathComponent("manifest-link.json")
        try canonicalManifest(videos: ["clip.mov"], photoFolder: nil).write(to: manifest)
        XCTAssertEqual(link(manifest.path, manifestLink.path), 0)
        XCTAssertThrowsError(
            try manifestArguments(root: root, manifest: manifest).resolveInput()
        )
        XCTAssertThrowsError(
            try manifestArguments(root: root, manifest: manifestLink).resolveInput()
        )

        let oversized = root.appendingPathComponent("oversized.json")
        try Data(repeating: 0x20, count: 64 * 1_024 + 1).write(to: oversized)
        XCTAssertThrowsError(
            try manifestArguments(root: root, manifest: oversized).resolveInput()
        )
    }

    func testSharedResolverContinuityRejectsSamePathEntryReplacement() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = root.appendingPathComponent("capture.mov")
        let manifest = root.appendingPathComponent("inputs.json")
        let videoData = Data("stable-video-bytes".utf8)
        try videoData.write(to: video)
        try canonicalManifest(
            videos: ["capture.mov"],
            photoFolder: nil
        ).write(to: manifest)
        let initial = try PackagedProjectInputResolver.resolve(
            manifestURL: manifest,
            inputRoot: root
        )
        try FileManager.default.removeItem(at: video)
        try videoData.write(to: video)
        let replacement = try PackagedProjectInputResolver.resolve(
            manifestURL: manifest,
            inputRoot: root
        )

        XCTAssertNotEqual(replacement, initial)
        XCTAssertNotEqual(
            replacement.continuityTokenSHA256,
            initial.continuityTokenSHA256
        )
    }

    func testMarkerSchemaThreeRequiresExactManifestFieldClosure() throws {
        let manifestDigest = String(repeating: "a", count: 64)
        let manifest = marker(inputManifestSHA256: manifestDigest)
        let manifestData = try PackagedProjectMarkerCodec.encodeCanonical(manifest)
        XCTAssertEqual(
            try PackagedProjectMarkerCodec.decodeCanonical(manifestData),
            manifest
        )
        let manifestObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        XCTAssertEqual(
            manifestObject["inputManifestSHA256"] as? String,
            manifestDigest
        )
        XCTAssertEqual(manifestObject.count, 16)

        var missingDigest = manifestObject
        missingDigest.removeValue(forKey: "inputManifestSHA256")
        let missingDigestData = try JSONSerialization.data(
            withJSONObject: missingDigest,
            options: [.sortedKeys]
        )
        XCTAssertThrowsError(
            try PackagedProjectMarkerCodec.decodeCanonical(missingDigestData)
        )

        var uppercaseDigest = manifestObject
        uppercaseDigest["inputManifestSHA256"] = manifestDigest.uppercased()
        let uppercaseData = try JSONSerialization.data(
            withJSONObject: uppercaseDigest,
            options: [.sortedKeys]
        )
        XCTAssertThrowsError(
            try PackagedProjectMarkerCodec.decodeCanonical(uppercaseData)
        )

        var manifestWithExtra = manifestObject
        manifestWithExtra["unexpected"] = true
        let extraData = try JSONSerialization.data(
            withJSONObject: manifestWithExtra,
            options: [.sortedKeys]
        )
        XCTAssertThrowsError(
            try PackagedProjectMarkerCodec.decodeCanonical(extraData)
        )
    }

    private func manifestArguments(root: URL, manifest: URL) throws -> PackagedProjectArguments {
        try PackagedProjectArguments.parse(
            arguments(root: root) + [
                "--input-manifest", manifest.path,
                "--input-root", root.path,
            ]
        )
    }

    private func arguments(root: URL) -> [String] {
        [
            "--project", root.appendingPathComponent("Project.easysplatproj").path,
            "--marker", root.appendingPathComponent("marker.json").path,
            "--app-version", "1.0.0",
            "--expected-release-verification-token-sha256", String(repeating: "1", count: 64),
            "--expected-executable", root.appendingPathComponent("EasySplat").path,
            "--expected-executable-sha256", String(repeating: "2", count: 64),
            "--expected-executable-bytes", "42",
            "--evidence", root.appendingPathComponent("attestation.md").path,
        ]
    }

    private func canonicalManifest(
        videos: [String],
        photoFolder: String?
    ) throws -> Data {
        let object: [String: Any] = [
            "photoFolder": photoFolder ?? NSNull(),
            "schemaVersion": 1,
            "videos": videos,
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func marker(inputManifestSHA256: String) -> PackagedProjectMarker {
        PackagedProjectMarker(
            schemaVersion: 3,
            releaseVerificationTokenSHA256: String(repeating: "1", count: 64),
            appVersion: "1.0.0",
            executablePath: "/Applications/EasySplat.app/Contents/MacOS/EasySplatApp",
            executableBytes: 42,
            executableSHA256: String(repeating: "2", count: 64),
            toolchainRoot: "/tmp/toolchain",
            requestedCapabilities: ["runtime.core"],
            inputPath: "/tmp/inputs",
            inputManifestSHA256: inputManifestSHA256,
            projectRoot: "/tmp/Project.easysplatproj",
            outputPlyPath: "/tmp/Project.easysplatproj/Output/splat.ply",
            outputBytes: 128,
            outputVertices: 1,
            outputFormat: "ascii",
            outputSHA256: String(repeating: "3", count: 64)
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EasySplat-release-verifier-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
