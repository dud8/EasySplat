#!/usr/bin/env python3

import base64
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]


class BuildDMGTrustBoundaryTests(unittest.TestCase):
    def test_production_requires_a_prepared_release_before_build_work(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as raw:
            fixture = Path(raw).resolve()
            repository = fixture / "repository"
            build_root = fixture / "build"
            output = fixture / "output"
            (repository / "scripts/release/lib").mkdir(parents=True)
            shutil.copy2(
                ROOT / "scripts/release/build_dmg.sh",
                repository / "scripts/release/build_dmg.sh",
            )
            shutil.copy2(
                ROOT / "scripts/release/lib/strict_semver.sh",
                repository / "scripts/release/lib/strict_semver.sh",
            )

            result = subprocess.run(
                [
                    os.fspath(repository / "scripts/release/build_dmg.sh"),
                    "--app-version",
                    "0.2.0",
                    "--toolchain-version",
                    "2.0.0",
                    "--manifest-url",
                    "https://example.com/manifest.json",
                    "--core-artifact-url",
                    "https://example.com/core.zip",
                    "--da3-base-artifact-url",
                    "https://example.com/base.zip",
                    "--da3-small-artifact-url",
                    "https://example.com/small.zip",
                    "--build-root",
                    os.fspath(build_root),
                    "--output-dir",
                    os.fspath(output),
                    "--use-existing-toolchain",
                    "--production",
                    "--identity-fingerprint",
                    "A" * 40,
                    "--team-id",
                    "ABCDE12345",
                    "--notary-keychain-profile",
                    "easysplat-notary",
                ],
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertIn("requires a prepared release", result.stderr)
            self.assertFalse(build_root.exists())
            self.assertFalse(output.exists())

    def test_prepared_artifact_manifest_tool_is_never_executed(self):
        with tempfile.TemporaryDirectory(dir="/private/tmp") as raw:
            fixture = Path(raw).resolve()
            repository = fixture / "repository"
            prepared = fixture / "prepared"
            trusted_tool = fixture / "trusted" / "ManifestTool"
            malicious_marker = fixture / "malicious-executed"
            trusted_marker = fixture / "trusted-executed"

            (repository / "scripts/release/lib").mkdir(parents=True)
            (repository / "EasySplatApp/Resources").mkdir(parents=True)
            shutil.copy2(
                ROOT / "scripts/release/build_dmg.sh",
                repository / "scripts/release/build_dmg.sh",
            )
            shutil.copy2(
                ROOT / "scripts/release/lib/strict_semver.sh",
                repository / "scripts/release/lib/strict_semver.sh",
            )
            for helper in (
                "generate_release_metadata.py",
                "prepared_release.py",
                "publish_release_files.py",
            ):
                (repository / "scripts/release" / helper).write_text(
                    "raise SystemExit(0)\n", encoding="utf-8"
                )

            key = base64.b64encode(bytes(range(32))).decode("ascii") + "\n"
            (repository / "EasySplatApp/Resources/public_key_ed25519.txt").write_text(
                key, encoding="ascii"
            )
            (prepared / "toolchain/out").mkdir(parents=True)
            (prepared / "toolchain/public_key_ed25519.txt").write_text(
                key, encoding="ascii"
            )
            (prepared / "toolchain/manifest.json").write_text("{}\n", encoding="utf-8")
            for name in (
                "toolchain-macos-arm64-2.0.0-core.zip",
                "toolchain-geometry-da3-base-2.0.0.zip",
                "toolchain-geometry-da3-small-2.0.0.zip",
            ):
                (prepared / "toolchain/out" / name).write_bytes(b"fixture")

            app = prepared / "product/EasySplat.app"
            (app / "Contents/Resources").mkdir(parents=True)
            (app / "Contents/Info.plist").write_text(
                """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>EasySplatReleaseChannel</key><string>production</string>
</dict></plist>
""",
                encoding="utf-8",
            )
            (app / "Contents/Resources/release_channel.txt").write_text(
                "production release", encoding="utf-8"
            )
            (prepared / "product/EasySplat.app.dSYM").mkdir(parents=True)
            prepared_manifest = prepared / "prepared-release.json"
            prepared_manifest.write_text("{}\n", encoding="utf-8")
            prepared_manifest_sha256 = hashlib.sha256(
                prepared_manifest.read_bytes()
            ).hexdigest()
            malicious_tool = prepared / "product/ManifestTool"
            malicious_tool.write_text(
                "#!/bin/bash\nprintf malicious >\"$MALICIOUS_MARKER\"\nexit 91\n",
                encoding="utf-8",
            )
            malicious_tool.chmod(0o500)

            trusted_tool.parent.mkdir()
            trusted_tool.write_text(
                "#!/bin/bash\nprintf trusted >\"$TRUSTED_MARKER\"\nexit 0\n",
                encoding="utf-8",
            )
            trusted_tool.chmod(0o500)

            environment = os.environ.copy()
            environment["MALICIOUS_MARKER"] = os.fspath(malicious_marker)
            environment["TRUSTED_MARKER"] = os.fspath(trusted_marker)
            result = subprocess.run(
                [
                    os.fspath(repository / "scripts/release/build_dmg.sh"),
                    "--app-version",
                    "0.2.0",
                    "--toolchain-version",
                    "2.0.0",
                    "--manifest-url",
                    "https://example.com/manifest.json",
                    "--core-artifact-url",
                    "https://example.com/core.zip",
                    "--da3-base-artifact-url",
                    "https://example.com/base.zip",
                    "--da3-small-artifact-url",
                    "https://example.com/small.zip",
                    "--use-existing-toolchain",
                    "--prepared-release-root",
                    os.fspath(prepared),
                    "--prepared-manifest-sha256",
                    prepared_manifest_sha256,
                    "--source-commit",
                    "0123456789abcdef0123456789abcdef01234567",
                    "--manifest-tool-bin",
                    os.fspath(trusted_tool),
                    "--production",
                    "--identity-fingerprint",
                    "A" * 40,
                    "--team-id",
                    "ABCDE12345",
                    "--notary-keychain-profile",
                    "easysplat-notary",
                ],
                check=False,
                capture_output=True,
                text=True,
                env=environment,
            )

            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertTrue(trusted_marker.is_file(), result.stderr)
            self.assertFalse(malicious_marker.exists(), result.stderr)
            self.assertIn("prepare-release", result.stderr)


if __name__ == "__main__":
    unittest.main()
