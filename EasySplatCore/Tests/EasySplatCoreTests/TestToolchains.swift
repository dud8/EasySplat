import Foundation
@testable import EasySplatCore

enum TestToolchains {
    static func vggtToolchain(root: URL, createFiles: Bool = false) throws -> VggtToolchain {
        let vggtRoot = root.appendingPathComponent("vggt_mps", isDirectory: true)
        let sfmTool = vggtRoot.appendingPathComponent("bin/easysplat_vggt_sfm")
        let python = vggtRoot.appendingPathComponent("python/bin/python3")
        let models = vggtRoot.appendingPathComponent("models", isDirectory: true)

        if createFiles {
            let fm = FileManager.default
            try fm.createDirectory(at: sfmTool.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: sfmTool.path, contents: Data())
            try fm.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
            let pythonStub = [
                "#!/usr/bin/env bash",
                "echo 'python stub'",
                ""
            ].joined(separator: "\n")
            try pythonStub.write(to: python, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
            try fm.createDirectory(at: models, withIntermediateDirectories: true)
        }

        return VggtToolchain(root: vggtRoot, sfmTool: sfmTool, python: python, models: models)
    }

    static func learnedSfmToolchain(root: URL, createFiles: Bool = false) throws -> LearnedSfmToolchain {
        let learnedRoot = root.appendingPathComponent("learned_sfm", isDirectory: true)
        let matchTool = learnedRoot.appendingPathComponent("bin/easysplat_match")
        let python = learnedRoot.appendingPathComponent("python/bin/python3")
        let models = learnedRoot.appendingPathComponent("models", isDirectory: true)

        if createFiles {
            let fm = FileManager.default
            try fm.createDirectory(at: matchTool.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: matchTool.path, contents: Data())
            try fm.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
            let probeStub = [
                "#!/usr/bin/env bash",
                "cat <<'JSON'",
                "{\"pythonMachine\":\"arm64\",\"platform\":\"test\",\"torchVersion\":\"2.1.0\",\"mpsBuilt\":true,\"mpsAvailable\":true,\"mpsAllocOK\":true,\"failure\":null}",
                "JSON",
                ""
            ].joined(separator: "\n")
            try probeStub.write(to: python, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
            try fm.createDirectory(at: models, withIntermediateDirectories: true)
        }

        return LearnedSfmToolchain(root: learnedRoot, matchTool: matchTool, python: python, models: models)
    }
}
