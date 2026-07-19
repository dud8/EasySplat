from __future__ import annotations

from pathlib import Path
import importlib.util
import re
import unittest


ROOT = Path(__file__).resolve().parents[3]
RELEASE = ROOT / "scripts" / "release"
WORKFLOW = ROOT / ".github" / "workflows" / "release-app.yml"
TOOLCHAIN_WORKFLOW = ROOT / ".github" / "workflows" / "toolchain-publish.yml"


class StableReleaseContractTests(unittest.TestCase):
    def test_publication_verifier_accepts_no_app_benchmark_identity(self) -> None:
        module_path = RELEASE / "verify_publication_bundle.py"
        spec = importlib.util.spec_from_file_location("stable_publication", module_path)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        args = module.parser().parse_args(
            [
                "verify-build",
                "--release-mode",
                "production",
                "--bundle",
                "/tmp/bundle",
                "--output",
                "/tmp/output",
                "--toolchain-public-key",
                "/tmp/key",
                "--app-version",
                "0.2.0",
                "--toolchain-version",
                "2.0.0",
                "--source-repository",
                "dud8/EasySplat",
                "--source-commit",
                "0" * 40,
                "--tag",
                "v0.2.0",
            ]
        )
        self.assertIsNone(args.benchmark_suite)
        self.assertIsNone(args.benchmark_run_id)

    def test_release_entrypoint_has_stable_modes_and_name(self) -> None:
        self.assertFalse((RELEASE / "verify_beta.sh").exists())
        verifier = RELEASE / "verify_release.sh"
        self.assertTrue(verifier.is_file())
        source = verifier.read_text(encoding="utf-8")
        self.assertIn("--release-mode development-unsigned|production", source)
        self.assertIn("easysplat_is_strict_semver_stable", source)
        self.assertNotIn("unsigned-beta", source)
        self.assertNotIn("signed-beta", source)
        self.assertNotIn("public beta", source.lower())

    def test_app_builder_exposes_honest_release_modes(self) -> None:
        source = (RELEASE / "build_app.sh").read_text(encoding="utf-8")
        for option in ("--development-unsigned", "--prepare-release", "--production"):
            self.assertIn(option, source)
        self.assertIn("easysplat_is_strict_semver_stable", source)
        self.assertNotIn("--unsigned-beta", source)
        self.assertNotIn("--signed-beta", source)
        self.assertNotIn("--prepare-signed-beta", source)
        self.assertNotIn("public beta", source.lower())

    def test_dmg_builder_production_is_real_and_stable_only(self) -> None:
        source = (RELEASE / "build_dmg.sh").read_text(encoding="utf-8")
        self.assertIn('--production)', source)
        self.assertIn('RELEASE_MODE="production"', source)
        self.assertIn("easysplat_is_strict_semver_stable", source)
        self.assertNotIn("Production DMG builds are not available", source)
        self.assertNotIn("--signed-beta", source)
        self.assertNotIn("public beta", source.lower())

    def test_release_workflow_prepares_a_stable_draft_without_forced_failure(self) -> None:
        source = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn('default: "0.2.0"', source)
        for environment in (
            "release-verification",
            "release-signing",
            "release-publication",
        ):
            self.assertIn(f"environment: {environment}", source)
        self.assertIn("scripts/release/verify_release.sh", source)
        self.assertIn("--production", source)
        self.assertIn('"prerelease": False', source)
        self.assertNotIn("public-beta", source)
        self.assertNotIn("--signed-beta", source)
        self.assertNotIn("shipping-ui-verification", source)
        self.assertNotIn("Automatic publication is blocked", source)
        self.assertNotIn("The workflow did not publish the stable release", source)
        self.assertIn("Verified stable release draft", source)

    def test_release_benchmark_evidence_is_optional_but_authenticated_when_present(self) -> None:
        source = WORKFLOW.read_text(encoding="utf-8")
        input_block = source.split("      benchmark_run_id:\n", 1)[1].split(
            "\n\npermissions:", 1
        )[0]
        self.assertIn("required: false", input_block)
        self.assertIn("if [ -n \"$INPUT_BENCHMARK_RUN_ID\" ]", source)
        self.assertIn("actions/runs/$INPUT_BENCHMARK_RUN_ID", source)

    def test_toolchain_publication_uses_release_environment_and_stable_default(self) -> None:
        source = TOOLCHAIN_WORKFLOW.read_text(encoding="utf-8")
        version_block = source.split("      version:\n", 1)[1].split(
            "      app_version:\n", 1
        )[0]
        self.assertIn('default: "2.0.0"', version_block)
        self.assertIn('default: "0.2.0"', source)
        self.assertIn("environment: toolchain-release", source)
        self.assertIn("environment: toolchain-publication", source)
        self.assertNotIn("environment: release-signing", source)
        self.assertNotIn("public-beta", source)


if __name__ == "__main__":
    unittest.main()
